module TypeCheck( buildTypeInformation
                , TypeInfo) where

import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State

import qualified Data.Map as M
import Data.Maybe
import qualified Data.Set as S

import AST
import Lexer
import Utility
import SpecialFunctions
import CompileError


type TypeCheckMonad = ReaderT LocInfo (StateT Context (Except PhaseError))
data Context = Context { returnType             :: Type
                       , activeBlocks           :: [BlockID]
--                        , definitionLocationInfo :: DefinitionLocationInfo
                       , variableTypeInfo       :: TypeInfo
                       , functionTypeInfo       :: OverloadInfo
                       , classInfo              :: ClassInfo
                       } deriving (Show, Eq)
-- (Type, BlockID, DefinitionLocationInfo)
-- type TypeInfo = M.Map VariableLocation Type
-- data VariableLocation = SLoc BlockID Identifier deriving (Eq, Ord, Show)
-- type DefinitionLocationInfo = M.Map Identifier BlockID
type TypeInfo = M.Map Identifier MangledIdentifier
type OverloadInfo = M.Map (Identifier, [Type]) Type


buildTypeInformation :: Program -> Either PhaseError ProgramTyped
buildTypeInformation = runTCM . btiProgram


btiProgram :: Program -> TypeCheckMonad ProgramTyped
btiProgram (Program fns cls) = do
    buildClassInfo cls
    forM_ fns $ \(FnDef tRet ident args _ loc) -> local (const loc) $ do
        let argsTypes = map (\(Arg t _ _) -> t) args
        checkType $ TFunction tRet argsTypes
        writeFunctionInfo ident argsTypes tRet
    fns' <- forM fns $ \(FnDef tRet ident args (SLocInfo body@(Block bid stms) loc) floc) ->
        local (const loc) $ withBlock bid $ do
            let argsTypes = map (\(Arg t _ _) -> t) args
            args' <- forM args $ \(Arg t ident loc) -> local (const loc) $ do
                ident' <- writeVariableInfo ident t
                return $ Arg t ident' loc
            ident' <- mangleFunction ident argsTypes
            body' <- withReturnType tRet $ Block bid <$> mapM btiStmt stms
            return $ FnDef tRet ident' args' body' floc
    return $ Program fns' cls


buildClassInfo :: [ClassDef] -> TypeCheckMonad ()
buildClassInfo cls = do
    let allDefs = map (\(ClassDef n mbs _) -> (n, mbs)) cls
               ++ map (\x -> (x, [])) builtinTypeNames
    whenJust (findDuplicateOrd $ map fst allDefs) $ \d ->
        throwErrorRLoc $ "Duplicate class declarations for " ++ d
    modify $ \c -> c { classInfo = M.fromList allDefs }
    forM_ cls $ \(ClassDef n mbs loc) -> local (const loc) $ do
        let (fieldNames, types) = unzip mbs
        -- Check if there are no duplicate fields and all types are known
        mapM_ checkType types
        whenJust (findDuplicateOrd fieldNames) $ \d ->
            throwErrorRLoc $ "Duplicate definitions of field " ++ d ++ " in class " ++ n


checkType :: Type -> TypeCheckMonad ()
checkType (TNamed s) = do
    m <- gets $ M.lookup s . classInfo
    whenNothing m $
        if s == "void"
            then throwErrorRLoc "void is not a valid value type"
            else throwErrorRLoc $ "Unknown type: " ++ s
checkType (TArray t) = checkType t
checkType (TFunction tRet tArgs) = do
    mapM_ checkType tArgs
    when (tRet /= tVoid) $ checkType tRet
checkType TNull = return ()


btiStmt :: Stmt -> TypeCheckMonad StmtTyped
btiStmt (Assign e1 e2)         = do
    (e1', te1) <- btiExpr e1
    (e2', te2) <- btiExpr e2
    typeCompare te1 te2
    return $ Assign e1' e2'
btiStmt (Block bid stmts)      = withBlock bid $ Block bid <$> mapM btiStmt stmts
btiStmt (Decl t items)         = do
    checkType t
    Decl t <$> mapM (btiItem t) items
btiStmt (Decr e)               = do
    (e', te) <- btiExpr e
    typeCompare tInt te
    return $ Decr e'
btiStmt Empty                  = return Empty
btiStmt (If cond s1 s2)        = do
    (cond', tcond) <- btiExpr cond
    typeCompare tBool tcond
    If cond' <$> btiStmt s1 <*> btiStmt s2
btiStmt (Incr e)               = do
    (e', te) <- btiExpr e
    typeCompare tInt te
    return $ Incr e'
btiStmt (Return e)             = do
    tRet <- gets returnType
    (e', te) <- btiExpr e
    typeCompare tRet te
    return $ Return e'
btiStmt (SExpr e)              = SExpr . fst <$> btiExpr e
btiStmt VReturn                = do
    tRet <- gets returnType
    typeCompare tVoid tRet
    return VReturn
btiStmt (While cond stmt)      = do
    (cond', tcond) <- btiExpr cond
    typeCompare tBool tcond
    While cond' <$> btiStmt stmt
btiStmt (SLocInfo s loc)       = local (const loc) $ btiStmt s


btiItem :: Type -> Item -> TypeCheckMonad ItemTyped
btiItem t (Item ident me loc) = local (const loc) $ do
    e' <- case me of
        Just e  -> do
            (e'', te) <- btiExpr e
            typeCompare t te
            return $ Just e''
        Nothing -> return Nothing
    blocks <- gets activeBlocks
    ident' <- writeVariableInfo ident t
    return $ Item ident' e' loc


typeCompare :: Type -> Type -> TypeCheckMonad ()
typeCompare (TArray _) TNull = return ()
typeCompare (TNamed _) TNull = return ()
typeCompare t1 t2 = when (t1 /= t2) $
    throwErrorRLoc $ "Expected type " ++ show t1 ++ ", got " ++ show t2


btiExpr :: Expr -> TypeCheckMonad (ExprTyped, Type)
btiExpr (EString s)           = return (EString s, tString)
btiExpr (EApp ident args)     = do
    (args', tArgs) <- unzip <$> mapM btiExpr args
    ident' <- mangleFunction ident tArgs
    let TFunction tRet _ = identifierType ident'
    return (EApp ident' args', tRet)
btiExpr (EBoolLiteral b)      = return (EBoolLiteral b, tBool)
btiExpr (EIntLiteral i)       = return (EIntLiteral i, tInt)
btiExpr ENull                 = return (ENull, TNull)
btiExpr (ENew t@(TArray _) [e]) = do
    (e', te) <- btiExpr e
    typeCompare tInt te
    return (ENew t [e'], t)
btiExpr (ENew t@(TNamed _) []) = return (ENew t [], t)
btiExpr (EVar ident)          = do
    ident' <- mangleVariable ident
    return (EVar ident', identifierType ident')
btiExpr (ELocInfo e loc)      = local (const loc) $ btiExpr e


writeVariableInfo :: Identifier -> Type -> TypeCheckMonad MangledIdentifier
writeVariableInfo ident t = do
    blocks <- gets activeBlocks
    oldDefinition <- gets $ M.lookup ident . variableTypeInfo
    let wasDefined = maybe False ((blocks==) . identifierScope) oldDefinition
    when wasDefined $ throwErrorRLoc $ "Variable " ++ show ident ++ " was already defined"
    let mangledIdent = MangledIdentifier ident t blocks
    modify $ \c -> c { variableTypeInfo = M.insert ident mangledIdent $ variableTypeInfo c }
    return mangledIdent


writeFunctionInfo :: Identifier -> [Type] -> Type -> TypeCheckMonad ()
writeFunctionInfo ident tArgs tRet = do
    wasDefined <- gets $ (Nothing/=) . M.lookup (ident, tArgs) . functionTypeInfo
    when wasDefined $ throwErrorRLoc $ "Multiple overloads of function " ++ show ident
                                    ++ " with the same arguments: " ++ show tArgs
    modify $ \c -> c { functionTypeInfo = M.insert (ident, tArgs) tRet $ functionTypeInfo c }


withReturnType :: Type -> TypeCheckMonad a -> TypeCheckMonad a
withReturnType = withPartialState returnType $ \t c -> c { returnType = t }


withBlock :: BlockID -> TypeCheckMonad a -> TypeCheckMonad a
withBlock bid m = do
    let extract c = (activeBlocks c, variableTypeInfo c)
    (blocks, vtInfo) <- gets extract
    withPartialState
        extract
        (\(b, vti) c -> c { activeBlocks = b, variableTypeInfo = vti })
        (bid : blocks, vtInfo)
        m


getVariableType :: Identifier -> TypeCheckMonad Type
getVariableType ident = identifierType <$> mangleVariable ident
    -- dli <- gets definitionLocationInfo
    -- info <- gets typeInfo
    -- case M.lookup ident dli >>= \loc -> M.lookup (SLoc loc ident) info of
    --     Just t  -> return t
    --     Nothing -> throwErrorRLoc $ "Unknown variable: " ++ show ident


runTCM :: TypeCheckMonad a -> Either PhaseError a
runTCM = runExcept . (`evalStateT` defaultContext) . (`runReaderT` NoLocInfo)


defaultContext :: Context
defaultContext = Context { returnType       = tVoid
                         , activeBlocks     = [0]
                         , variableTypeInfo = defaultVariableTypeInfo
                         , functionTypeInfo = defaultFunctionTypeInfo
                         , classInfo        = M.empty
                         }


defaultVariableTypeInfo = M.fromList []
defaultFunctionTypeInfo = M.fromList [ (("printInt", [tInt]), tVoid)
                                     , (("readInt", []), tInt)
                                     , (("printString", [tString]), tVoid)
                                     , (("readString", []), tString)
                                     , (("error", []), tVoid)
                                     ]


mangleVariable :: Identifier -> TypeCheckMonad MangledIdentifier
mangleVariable i = do
    vti <- gets variableTypeInfo
    case M.lookup i vti of
        Nothing -> throwErrorRLoc $ "Not in scope: variable " ++ show i
        Just mi -> return mi


mangleFunction :: Identifier -> [Type] -> TypeCheckMonad MangledIdentifier
mangleFunction i tArgs = do
    -- Check if it is a special function
    tRet <- do
        ci <- gets classInfo
        spec <- returnTypeOfSpecialFunction ci i tArgs
        case spec of
            Just t -> return t
            Nothing -> do
                fti <- gets functionTypeInfo
                case M.lookup (i, tArgs) fti of
                    Nothing   -> throwErrorRLoc $ "Unknown function: "
                                    ++ show i ++ " with args " ++ show tArgs
                    Just t    -> return t
    return $ MangledIdentifier i (TFunction tRet tArgs) [0]

