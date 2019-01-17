module Dynamic where

import Algebra
import qualified Data.Map as M
import Syntax
import Data.Maybe
import Data.List

data IColumn = IColumn {
    nameICol :: String,
    typeICol :: Type,
    colmodICol :: [ColumnModifier]
}

data Constant = BoolConst Bool
            | IntConst Int
            | StringConst String

data IVar = IVar {
    nameIVar :: String,
    typeIVar :: Type,
    valIVar :: Constant
}

type TableEnv = M.Map String (M.Map String IColumn)

type VarEnv = M.Map String IVar

data Environment = Environment {
    table :: TableEnv,
    var :: VarEnv
}

data Code = Code {
    upgrade :: [String],
    downgrade :: [String]
} deriving (Show)

type Migration = Environment -> (Code, Environment)

generate :: Hasql -> Code
generate h = foldHasql (hasql1, init1, table1,
            col1, colmod1, id, up1,
            (declstat, assstat, operstat),
            id,
            (\(StringConst s) -> ArgExpression $ ConstString s, ArgLambda, \icol -> ArgColumn $ Column (nameICol icol) (typeICol icol) (colmodICol icol), ArgStringList),
            undefined,
            (undefined, undefined, undefined, undefined, undefined, StringConst),
            id) h


hasql1 :: TableEnv -> Migration -> Code
hasql1 i u = fst $ u (Environment { table = i, var = M.empty })

init1 :: [(String, M.Map String IColumn)] -> TableEnv
init1 ts = foldr (\(k, icols) prev -> M.insert k icols prev) M.empty ts

table1 :: String -> [IColumn] -> (String, M.Map String IColumn)
table1 s cs = (s, foldr (\c prev -> M.insert (nameICol c) c prev) M.empty cs)

col1 :: String -> Type -> [ColumnModifier] -> IColumn
col1 s t cms = IColumn { typeICol = t, nameICol = s, colmodICol = cms }

colmod1 :: ColumnModifier -> ColumnModifier
colmod1 = id

up1 :: [Migration] -> Migration
up1 ms env
    = up' ms (initial, env)
    where
        up' :: [Migration] -> (Code, Environment) -> (Code, Environment)
        up' [] acc = acc
        up' (s:ss) acc = up' ss (process s acc)
        process :: Migration -> (Code, Environment) -> (Code, Environment)
        process current (prevCode, prevEnv)
            = let (nextCode, nextEnv) = current prevEnv
                in (codeConcat nextCode prevCode, nextEnv)
        initial = Code {upgrade = [], downgrade = []}

declstat :: String -> Type -> Constant -> Migration
declstat s t constExpr env
    = (Code {upgrade = [], downgrade = []}, Environment { var = M.insert s
        (IVar {nameIVar = s, typeIVar = t, valIVar = constExpr}) (var env), table = table env})

assstat :: String -> Constant -> Migration
assstat s c env
    = (Code {upgrade = [], downgrade = []}, Environment { var = M.update updateValue s (var env), table = table env })
    where
        updateValue IVar { nameIVar = n, typeIVar = t }
            = Just $ IVar { nameIVar = n, typeIVar = t, valIVar = c }

operstat :: Operation -> [Argument] -> Migration
operstat OperationAdd args env = doOperationAdd env tableName columnName lambda
    where
        tableName = extractIdent (args!!0)
        columnName = extractColumn (args!!1)
        lambda = extractLambda (args!!2)
operstat OperationSplit args env = doOperationSplit env tableName columnNames newTableName
    where
        tableName = extractIdent (args!!0)
        columnNames = extractStringList (args!!1)
        newTableName = extractString (args!!2)
operstat OperationDecouple args env = undefined
operstat OperationNormalize args env = undefined
operstat OperationRename args env = doOperationRename env tableName newTableName
    where
        tableName = extractIdent (args!!0)
        columnNames = extractStringList (args!!1)
        newTableName = extractString (args!!2)

getPK :: Environment -> String -> IColumn
getPK env i = snd $ head $ filter (\(k,v) -> Primary `elem` colmodICol v) (M.toList (oldTableEnv env i))

fetched :: Environment -> String -> [String] -> [(String, Type)]
fetched env i ss = map (\colString -> (colString, typeICol (fetchColumn colString))) ss
    where 
        fetchColumn :: String -> IColumn
        fetchColumn c = fromMaybe (error "Splitting on nonexisting column.") (M.lookup c (oldTableEnv env i))

oldTableEnv :: Environment -> String -> M.Map String IColumn
oldTableEnv env i =  fromJust $ M.lookup i $ table env

doOperationAdd :: Environment -> String -> Column -> Lambda -> (Code, Environment)
doOperationAdd env c lambda 
    = (
        Code {
            upgrade=[

            ],
            downgrade=[

            ]
        }
    , env)

doOperationDecouple :: Environment -> Expression -> [String] -> (Code, Environment)
doOperationDecouple env (Ident i) ss 
    = (Code 
        { upgrade=[
            "CREATE TABLE " ++ decoupledName ++ " ( "
            ++ nameICol columnPK ++ " " ++ show (typeICol columnPK) ++ " PRIMARY KEY NOT NULL,"
            ++ concatMap (\(colString, colType) -> concat [colString, " ", show colType, ","]) (fetched env i ss)
            ++ ");",
            "INSERT INTO " ++ decoupledName ++ " ( "
            ++ "SELECT  " ++ nameICol columnPK ++ ", " ++ nameInsert ", "
            ++ "FROM " ++ i ++ " "
            ++ ");",
            "ALTER TABLE " ++ i ++ " DROP COLUMN " ++ nameInsert ", DROP COLUMN "  ++ ";"
        ], downgrade=[
            "ALTER TABLE " ++ i
            ++ "ADD COLUMN " ++ nameInsert ", ADD COLUMN " ++ ";",
            "INSERT INTO " ++ i ++ " ( " ++ nameInsert ", " ++ " )" ++ " ( "
            ++ "SELECT " ++ nameInsert ", "
            ++ "FROM " ++ decoupledName ++ " "
            ++ "WHERE " ++ i ++ "." ++ nameICol columnPK ++ " == " ++ decoupledName ++ "." ++ nameICol columnPK
            ++ ");",
            "DROP TABLE " ++ decoupledName ++ ";"
         ]
        }, env)
        where
            columnPK :: IColumn
            columnPK = getPK env i
            nameInsert :: String -> String
            nameInsert x = intercalate x ss
            decoupledName :: String
            decoupledName = i ++ "_decoupled" ++ (show $ count 0)
            count :: Int -> Int
            count x = case M.lookup (i ++ "_decoupled"  ++ show x) (table env) of 
                        Just _ -> count x + 1
                        Nothing -> x

doOperationNormalize :: Environment -> Expression -> String -> [String] -> (Code, Environment)
doOperationNormalize = undefined

doOperationSplit :: Environment -> Expression -> [String] -> String -> (Code, Environment)
doOperationSplit env (Ident i) ss s
    = (Code
        { upgrade=[
            "CREATE TABLE " ++ s ++ " ( "
            ++ nameICol columnPK ++ " " ++ show (typeICol columnPK) ++ " PRIMARY KEY NOT NULL,"
            ++ concatMap (\(colString, colType) -> concat [colString, " ", show colType, ","]) (fetched env i ss)
            ++ ");",
            "INSERT INTO " ++ s ++ " ( "
            ++ "SELECT  " ++ nameICol columnPK ++ ", " ++ nameInsert ", "
            ++ "FROM " ++ i + " "
            ++ ");",
            "ALTER TABLE " ++ i ++ " DROP COLUMN " ++ nameInsert ", DROP COLUMN "  ++ ";"
        ],
         downgrade=[
            "ALTER TABLE " ++ i ++ " "
            ++ "ADD COLUMN " ++ nameInsert ", ADD COLUMN " ++ ";",
            "INSERT INTO " ++ i ++ " ( " ++ nameInsert ", " ++ " )" ++ " ( "
            ++ "SELECT " ++ nameInsert ", "
            ++ "FROM " ++ s + " "
            ++ "WHERE " ++ i ++ "." ++ nameICol columnPK ++ " == " ++ s ++ "." ++ nameICol columnPK
            ++ ");",
            "DROP TABLE " ++ s ++ ";"
         ]}, env)
    where
          columnPK :: IColumn
          columnPK = getPK env i
          nameInsert :: String -> String
          nameInsert x = intercalate x (map fst (fetched env i ss))
          

doOperationRename :: Environment -> Expression -> String -> (Code, Environment)
doOperationRename env (Ident i) s
    = (Code { upgrade=["ALTER TABLE " ++ i ++ " RENAME TO " ++ s],
        downgrade=["ALTER TABLE " ++ s ++ " RENAME TO " ++ i] }, newEnv)
    where
        oldTable = M.lookup i (table env)
        removedTable = M.delete i (table env)
        newEnv = case oldTable of
            Just o -> Environment {var = var env, table = M.insert s o removedTable}
            Nothing -> error "The given table does not exist."

extractIdent :: Argument -> Expression
extractIdent (ArgExpression i@(Ident s)) = i
extractIdent a = error ("Ident expected, " ++ show a ++ " given.")

extractString :: Argument -> String
extractString (ArgExpression (ConstString s)) = s
extractString a = error ("ConstString expected, " ++ show a ++ " given.")

extractIdents :: Argument -> [String]
extractIdents (ArgStringList ss) = ss
extractIdents a = error ("[String] expected, " ++ show a ++ " given.")

extractLambda :: Argument -> Lambda
extractLambda (ArgLambda l) = l
extractLambda a = error ("Lambda expected, " ++ show a ++ " given.")

extractColumn :: Argument -> Column
extractColumn (ArgColumn c) = c
extractColumn a = error ("Column expected, " ++ show a ++ " given.")

extractStringList :: Argument -> [String]
extractStringList (ArgStringList ss) = ss
extractStringList a = error ("[String] expected, " ++ show a ++ " given.")

codeConcat :: Code -> Code -> Code
codeConcat c1 c2 = Code { upgrade = upgrade c1 ++ upgrade c2, downgrade = downgrade c1 ++ downgrade c2 }
