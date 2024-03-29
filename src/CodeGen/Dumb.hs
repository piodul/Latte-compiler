{-# LANGUAGE FlexibleContexts #-}
module CodeGen.Dumb(astToAsm) where

import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer
import Data.Generics
import Data.Int
import Data.List
import qualified Data.Map as M
import Data.Maybe
import qualified Data.Set as S

import AST hiding (And)
import CodeGen.Assembly
import CodeGen.AssemblyFormatters
import CompileError
import Lexer


data Context = Context { contextFunctionArguments :: [MangledIdentifier]
                       , contextStackVariables :: [MangledIdentifier]
                       , contextAssemblyFormatter :: AssemblyFormatter
                       , contextLiteralLabels :: M.Map String String
                       , contextClassInfo :: ClassInfo
                       , contextLocInfo :: LocInfo
                       }
type Mo = StateT Integer (WriterT String (ReaderT Context (Except PhaseError)))


astToAsm :: AssemblyFormatter -> ProgramTyped -> Either PhaseError String
astToAsm fmtr p@(Program fns cls) = 
    let ci = M.fromList $ map (\(ClassDef n mbs _) -> (n, mbs)) cls
    in runExcept
        . flip runReaderT (Context [] [] fmtr (collectStringLiterals p) ci NoLocInfo)
        . execWriterT $ flip evalStateT 0 $ do
            boilerplate
            literals <- asks contextLiteralLabels
            forM_ (M.toList literals) $ \(sz, label) -> do
                tellLabel $ ArgumentLabel label
                tellGlobalConst $ ConstString sz
            mapM_ generateFunction fns


boilerplate :: Mo ()
boilerplate = do
    bp <- asks $ formatterBoilerplate . contextAssemblyFormatter
    tell bp
    -- tellLn "global _start"
    -- tellLn "global main"
    -- tellLn "extern printInt"
    -- tellLn "extern __alloc_array"
    -- tellLn "extern error"
    -- tellLn "section .text"

    -- tellLn "_start:"
    -- tellLn "call main"
    -- tellI2 Mov RDI RAX
    -- tellI2 Mov RAX 60
    -- tellLn "syscall"


generateFunction :: FnDefTyped -> Mo ()
generateFunction (FnDef tRet ident args stmt loc) = local (insL loc) $ do
    tellLabel (ArgumentLabel $ identifierLabel ident)
    tellI1 Push RBP
    tellI2 Mov RBP RSP
    local (\c -> c { contextFunctionArguments = map (\(Arg _ ident _) -> ident) args }) $ do
        generateStatement stmt
        -- TODO: Only generate if function type is void
        generateStatement VReturn


generateStatement :: StmtTyped -> Mo ()
generateStatement (Block bid stms) = do
    let locals = getLocalNames stms
    unless (null locals) $
        tellI2 Sub RSP (fromIntegral $ length locals * 8 :: Int64)
    local (\c -> c { contextStackVariables = contextStackVariables c ++ locals }) $
        mapM_ generateStatement stms
    unless (null locals) $
        tellI2 Add RSP (fromIntegral $ length locals * 8 :: Int64)

generateStatement (Assign e1 e2) = do
    lval <- generateLValue e1
    case lval of
        Nothing -> do
            tellI1 Push RAX
            generateExpression e2
            tellI1 Pop R11
            tellI2 Mov (QWORD [toArgument R11]) RAX
        Just r -> do
            generateExpression e2
            tellI2 Mov r RAX

generateStatement (Decl t items) = do
    let work (Item ident Nothing loc) = local (insL loc) $ do
            loc <- varBaseLoc ident
            tellI2 Mov loc (0 :: Int64)
        work (Item ident (Just e) loc) = local (insL loc) $ do
            generateExpression e
            loc <- varBaseLoc ident
            tellI2 Mov loc RAX
    mapM_ work items

generateStatement (Decr e) = generateRementation Sub e

generateStatement Empty = tellI0 Nop

generateStatement (If e s1 s2) = do
    l1 <- nextTmpLabel
    l2 <- nextTmpLabel
    l3 <- nextTmpLabel
    generateExpression e
    tellI2 Test RAX RAX
    tellI1 (J Z) l2
    tellLabel l1
    generateStatement s1
    tellI1 Jmp l3
    tellLabel l2
    generateStatement s2
    tellLabel l3

generateStatement (Incr e) = generateRementation Add e

generateStatement (While e s) = do
    lCond <- nextTmpLabel
    lBody <- nextTmpLabel
    lEnd <- nextTmpLabel
    tellLabel lCond
    generateExpression e
    tellI2 Test RAX RAX
    tellI1 (J Z) lEnd
    tellLabel lBody
    generateStatement s
    tellI1 Jmp lCond
    tellLabel lEnd

generateStatement (SExpr e) =
    generateExpression e

generateStatement (Return e) = do
    generateExpression e
    generateStatement VReturn

generateStatement VReturn = do
    tellI0 Leave
    tellI0 Ret


generateRementation :: OpCode -> ExprTyped -> Mo ()
generateRementation op e = do
    lval <- generateLValue e
    case lval of
        Nothing -> do
            tellI2 Mov R11 $ QWORD [toArgument RAX]
            tellI2 op R11 (1 :: Int64)
            tellI2 Mov (QWORD [toArgument RAX]) R11
        Just r ->
            tellI2 op r (1 :: Int64)


getLocalNames :: [StmtTyped] -> [MangledIdentifier]
getLocalNames = concatMap worker
    where
        worker :: StmtTyped -> [MangledIdentifier]
        worker (Decl _ decls) = map (\(Item ident _ _) -> ident) decls
        worker _              = []


-- All expressions return their values in rax.
generateExpression :: ExprTyped -> Mo ()
generateExpression (EApp ident args) = functionCall ident args
generateExpression (EVar ident) = do
    loc <- varBaseLoc ident
    tellI2 Mov RAX loc
generateExpression (EString s) = do
    lits <- asks contextLiteralLabels
    let Just label = M.lookup s lits
    tellI2 Mov RAX $ QWORD [ArgumentLabel label]
generateExpression (EBoolLiteral True) = tellI2 Mov RAX (1 :: Int64)
generateExpression (EBoolLiteral False) = tellI2 Xor RAX RAX
generateExpression (EIntLiteral i) = tellI2 Mov RAX (fromInteger i :: Int64)
generateExpression ENull = tellI2 Mov RAX (0 :: Int64)
generateExpression (ENew (TArray _) [e]) = functionCallDirect "__alloc_array" [e]
generateExpression (ENew (TNamed s) []) = do
    l <- max 8 <$> getClassSize s -- malloc(0) can return null, we want to prevent that
    functionCallDirect "__alloc_object" [EIntLiteral $ fromIntegral l]


generateLValue :: ExprTyped -> Mo (Maybe Register)
generateLValue (EVar ident) = do
    loc <- varBaseLoc ident
    case loc of
        ArgumentRegister r -> return $ Just r
        _                  -> tellI2 Lea RAX loc >> return Nothing

generateLValue (EApp ident [e1, e2])
    | identifierLabel ident == "[]" = do
        calcTwoArguments e1 e2
        checkArrayBounds
        tellI2 Lea RAX $ QWORD [R11 ^+ (8 :: Int64) ^* RAX ^+ (8 :: Int64)]
        return Nothing

generateLValue (EApp ident [e])
    | head (identifierLabel ident) == '.' =
        case identifierType ident of
            TFunction _ [TArray _] -> throwErrorLoc "Array length is not assignable"
            TFunction _ [TNamed s] -> do
                r <- generateLValue e
                let mbName = tail $ identifierLabel ident
                n <- getOffsetInClass s mbName
                case r of
                    Nothing -> do
                        tellI2 Mov RAX $ QWORD [toArgument RAX]
                        tellI2 Add RAX $ toArgument n
                        return Nothing
                    Just rr -> throwErrorLoc "Internal error"
                
generateLValue _ = throwErrorLoc "Expression is not a lvalue"


functionCall :: MangledIdentifier -> [ExprTyped] -> Mo ()
functionCall ident [e]
    | identifierLabel ident == "-" = do
        generateExpression e
        tellI1 Neg RAX
    | identifierLabel ident == "!" = do
        generateExpression e
        tellI2 Xor RAX (1 :: Int64)
    | head (identifierLabel ident) == '.' = do
        generateExpression e
        case identifierType ident of
            TFunction _ [TArray _] ->
                tellI2 Mov RAX $ QWORD [toArgument RAX] -- It must be .length
            TFunction _ [TNamed s] -> do
                let mbName = tail $ identifierLabel ident
                n <- getOffsetInClass s mbName
                tellI2 Mov RAX $ QWORD [RAX ^+ n]
                
functionCall ident [e1, e2]
    | identifierLabel ident `elem` ["+", "-"]
    && identifierType ident == TFunction tInt [tInt, tInt] = do
        calcTwoArguments e1 e2
        fromJust $ lookup (identifierLabel ident)
            [ ("+", tellI2 Add RAX R11)
            , ("-", tellI2 Sub R11 RAX >> tellI2 Mov RAX R11)]
    | identifierLabel ident == "+"
    && identifierType ident == TFunction tString [tString, tString] =
        functionCallDirect "__add_strings" [e1, e2]
    | identifierLabel ident == "*" = do
        calcTwoArguments e1 e2
        tellI2 Mov R10 RDX
        tellI1 Mul R11
        tellI2 Mov RDX R10
    | identifierLabel ident `elem` ["/", "%"] = do
        calcTwoArguments e1 e2
        tellI2 Xchg RAX R11
        tellI2 Mov R10 RDX
        tellI2 Xor RDX RDX
        tellI1 Div R11
        when (identifierLabel ident == "%") $
            tellI2 Mov RAX RDX
        tellI2 Mov RDX R10
    | identifierLabel ident `elem` ["==", "!=", "<", "<=", ">", ">="] = do
        calcTwoArguments e1 e2
        tellI2 Cmp R11 RAX
        let flag = fromJust $ lookup (identifierLabel ident)
                [ ("==", E), ("!=", NE)
                , ("<", L),  ("<=", LE)
                , (">", G),  (">=", GE)]
        tellI1 (Set flag) AL
        tellI2 And RAX (0xFF :: Int64)
    | identifierLabel ident == "&&" = do
        l <- nextTmpLabel
        generateExpression e1
        tellI2 Test RAX RAX
        tellI1 (J Z) l
        generateExpression e2
        tellLabel l
    | identifierLabel ident == "||" = do
        l <- nextTmpLabel
        generateExpression e1
        tellI2 Test RAX RAX
        tellI1 (J NZ) l
        generateExpression e2
        tellLabel l
    | identifierLabel ident == "[]" = do
        calcTwoArguments e1 e2
        checkArrayBounds
        tellI2 Mov RAX $ QWORD [R11 ^+ (8 :: Int64) ^* RAX ^+ (8 :: Int64)]
functionCall ident args = functionCallDirect (identifierLabel ident) args


getOffsetInClass :: String -> String -> Mo Int64
getOffsetInClass s mb =
    asks $ (8*)
         . fromIntegral
         . fromJust
         . elemIndex mb
         . map fst
         . fromJust
         . M.lookup s
         . contextClassInfo


getClassSize :: String -> Mo Int64
getClassSize s =
    asks $ (8*) . fromIntegral . length . fromJust . M.lookup s . contextClassInfo


functionCallDirect :: String -> [ExprTyped] -> Mo ()
functionCallDirect ident args = do
    -- Need to preserve registers containing arguments of current function
    argNum <- asks (length . contextFunctionArguments)
    forM_ (take argNum registersForArguments) $ \reg ->
        tellI1 Push reg

    -- Reserve space for arguments, if neccessary
    let argSpace = max 0 $ length args - 6
    when (argSpace > 0) $
        tellI2 Sub RSP (fromIntegral argSpace * 8 :: Int64)

    -- Push ALL arguments on stack
    let methods = map (\r -> tellI1 Push RAX) [0..5]
                    ++ map (\i -> tellI2 Mov (QWORD [RSP ^+ (i * 8 :: Int64)]) RAX) [6..]
    forM_ (zip methods args) $ \(method, e) ->
        generateExpression e >> method

    -- Pop the first 6 arguments back into registers
    forM_ (reverse $ take (length args) registersForArguments) (tellI1 Pop)

    tellI1 Call (ArgumentLabel ident)

    when (argSpace > 0) $
        tellI2 Add RSP (fromIntegral argSpace * 8 :: Int64)

    -- Restore registers
    forM_ (reverse $ take argNum registersForArguments) $ \reg ->
        tellI1 Pop reg


calcTwoArguments :: ExprTyped -> ExprTyped -> Mo ()
calcTwoArguments e1 e2 = do
    generateExpression e1
    tellI1 Push RAX
    generateExpression e2
    tellI1 Pop R11

checkArrayBounds :: Mo ()
checkArrayBounds = do
    tellI2 Cmp (QWORD [toArgument R11]) RAX
    tellI1 (J BE) (ArgumentLabel "error")


collectStringLiterals :: ProgramTyped -> M.Map String String
collectStringLiterals p =
    let literals = everything S.union (S.empty `mkQ` f) p
        f :: ExprTyped -> S.Set String
        f (EString s) = S.singleton s
        f _           = S.empty
    in M.fromList $ zip (S.toList literals) $ map (\i -> "sz" ++ show i) [0..]


nextTmpLabel :: Mo Argument
nextTmpLabel = state $ \i -> (ArgumentLabel $ ".L" ++ show i, i + 1)


-- varBaseLoc :: MangledIdentifier -> Mo String
varBaseLoc :: MangledIdentifier -> Mo Argument
varBaseLoc ident = do
    mArgOffset <- asks (elemIndex ident . contextFunctionArguments)
    case mArgOffset of
        Just off -> return $ if off < 6
                                then toArgument $ registersForArguments !! off
                                else toArgument $ QWORD [RBP ^+ (fromIntegral (off - 6) * 8 + 16 :: Int64)]
        Nothing -> do
            mOffset <- asks (elemIndex ident . contextStackVariables)
            case mOffset of
                Just offset ->
                    return . toArgument $ QWORD [RBP ^+ negate (fromIntegral offset * 8 + 8 :: Int64)]
                Nothing -> throwErrorLoc $ "Identifier " ++ identifierLabel ident ++ " not found"


registersForArguments :: [Register]
registersForArguments = [RDI, RSI, RDX, RCX, R8, R9]


tellI :: Instruction -> Mo ()
tellI i = do
    conv <- asks $ formatterConverter . contextAssemblyFormatter
    tell $ conv i ++ "\n"


tellI0 :: OpCode -> Mo ()
tellI0 = tellI . I0

tellI1 :: (ToArgument a) => OpCode -> a -> Mo ()
tellI1 op a = tellI $ I1 op (toArgument a)

tellI2 :: (ToArgument a1, ToArgument a2) => OpCode -> a1 -> a2 -> Mo ()
tellI2 op a1 a2 = tellI $ I2 op (toArgument a1) (toArgument a2)


tellLabel :: Argument -> Mo ()
tellLabel (ArgumentLabel s) = tell $ s ++ ":\n"


tellGlobalConst :: GlobalConstant -> Mo ()
tellGlobalConst gc = do
    conv <- asks $ formatterConstantConverter . contextAssemblyFormatter
    tell $ conv gc ++ "\n"


throwErrorLoc :: String -> Mo a
throwErrorLoc s = do
    loc <- asks contextLocInfo
    throwError $ PhaseError loc s
    

insL :: LocInfo -> Context -> Context
insL loc c = c { contextLocInfo = loc }

