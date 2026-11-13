-- | Abstract syntax for Moss and its type language.
module Syntax where

import Data.Char (chr, ord)
import Data.List (intercalate, nub)
import qualified Data.Map.Strict as M

-- ---------------------------------------------------------------------------
-- Source positions

data Pos = Pos { posLine :: !Int, posCol :: !Int } deriving (Eq, Ord)

instance Show Pos where
  show (Pos l c) = show l ++ ":" ++ show c

noPos :: Pos
noPos = Pos 0 0

type Name = String

-- ---------------------------------------------------------------------------
-- Terms

data Lit = LInt Integer | LStr String | LBool Bool | LUnit
  deriving (Eq, Ord, Show)

data Pat
  = PWild
  | PVar Name
  | PLit Lit
  | PCon Pos Name [Pat]
  | PTuple [Pat]
  deriving Show

data Expr
  = EVar Pos Name
  | ECon Pos Name
  | ELit Pos Lit
  | EApp Pos Expr Expr
  | ELam Pos Name Expr
  | ELet Pos Pat Expr Expr
  | ELetRec Pos [(Name, Expr)] Expr
  | EIf Pos Expr Expr Expr
  | EMatch Pos Expr [(Pat, Expr)]
  | ETuple Pos [Expr]
  | ESeq Pos Expr Expr
  deriving Show

exprPos :: Expr -> Pos
exprPos e = case e of
  EVar p _ -> p; ECon p _ -> p; ELit p _ -> p; EApp p _ _ -> p
  ELam p _ _ -> p; ELet p _ _ _ -> p; ELetRec p _ _ -> p; EIf p _ _ _ -> p
  EMatch p _ _ -> p; ETuple p _ -> p; ESeq p _ _ -> p

data TyExpr = TyVar Name | TyCon Name [TyExpr] | TyFun TyExpr TyExpr | TyTuple [TyExpr]
  deriving Show

data Decl
  = DLet Pos Pat Expr
  | DLetRec Pos [(Name, Expr)]
  | DData Pos Name [Name] [(Name, [TyExpr])]
  | DExpr Pos Expr
  deriving Show

-- ---------------------------------------------------------------------------
-- Types

data Type
  = TV !Int
  | TC Name [Type]
  | TFun Type Type
  | TTup [Type]
  deriving (Eq, Show)

data Scheme = Forall [Int] Type deriving Show

tInt, tBool, tStr, tUnit :: Type
tInt = TC "Int" []
tBool = TC "Bool" []
tStr = TC "String" []
tUnit = TC "Unit" []

tList :: Type -> Type
tList a = TC "List" [a]

ftv :: Type -> [Int]
ftv t = nub (go t)
  where
    go (TV v) = [v]
    go (TC _ ts) = concatMap go ts
    go (TFun a b) = go a ++ go b
    go (TTup ts) = concatMap go ts

-- | Pretty-print several types with a shared, normalised variable naming
--   (so "expected a -> b, got Int -> a" uses the same letters consistently).
prettyTypes :: [Type] -> [String]
prettyTypes ts = map (render 0) ts
  where
    vars = nub (concatMap ftv ts)
    names = M.fromList (zip vars varNames)
    varNames = [ [chr (ord 'a' + i)] | i <- [0 .. 25] ] ++ [ 't' : show i | i <- [(1 :: Int) ..] ]
    -- precedence: 0 = top, 1 = left of arrow, 2 = constructor argument
    render :: Int -> Type -> String
    render _ (TV v) = M.findWithDefault ('?' : show v) v names
    render _ (TC c []) = c
    render p (TC c args) = paren (p >= 2) (unwords (c : map (render 2) args))
    render p (TFun a b) = paren (p >= 1) (render 1 a ++ " -> " ++ render 0 b)
    render _ (TTup xs) = "(" ++ intercalate ", " (map (render 0) xs) ++ ")"
    paren True s = "(" ++ s ++ ")"
    paren False s = s

prettyType :: Type -> String
prettyType t = head (prettyTypes [t])

prettyScheme :: Scheme -> String
prettyScheme (Forall _ t) = prettyType t
