{-# LANGUAGE LambdaCase #-}

-- | Strict, environment-based evaluator with closures, recursive bindings
--   tied with Haskell laziness, arbitrary-precision integers and a fuel
--   counter (used by the fuzzer to cut off divergent programs).
module Eval
  ( Value (..)
  , RunErr (..)
  , Env
  , Eval
  , runEval
  , evalDecl
  , evalExpr
  , initialEnv
  , showValue
  , showRunErr
  ) where

import Control.Monad (zipWithM)
import Control.Monad.State.Strict
import Control.Monad.Trans.Except
import qualified Data.Map.Strict as M
import Syntax
import System.IO (hFlush, stdout)

data Value
  = VInt !Integer
  | VStr !String
  | VBool !Bool
  | VUnit
  | VTup [Value]
  | VCon !Int !Name [Value]
  | VClo Env Name Expr
  | VPrim Name !Int [Value] ([Value] -> Eval Value)
  | VConF !Int !Name !Int [Value]

type Env = M.Map Name Value

data RunErr
  = Stuck String -- the evaluator "went wrong": impossible for well-typed programs
  | UserError String -- `error "..."`
  | MatchFail Pos
  | DivZero
  | CompareFun
  | OutOfFuel

showRunErr :: RunErr -> String
showRunErr = \case
  Stuck m -> "internal error (stuck): " ++ m
  UserError m -> "error: " ++ m
  MatchFail p -> "runtime error: match failure (match at " ++ show p ++ ")"
  DivZero -> "division by zero"
  CompareFun -> "cannot compare functions"
  OutOfFuel -> "out of fuel"

type Eval a = ExceptT RunErr (StateT Int IO) a

runEval :: Int -> Eval a -> IO (Either RunErr a, Int)
runEval fuel m = runStateT (runExceptT m) fuel

tick :: Eval ()
tick = do
  n <- lift get
  if n <= 0 then throwE OutOfFuel else lift (put (n - 1))

-- ---------------------------------------------------------------------------

apply :: Value -> Value -> Eval Value
apply f x = do
  tick
  case f of
    VClo env n body -> eval (if n == "_" then env else M.insert n x env) body
    VPrim n ar args impl ->
      let args' = args ++ [x]
       in if length args' == ar then impl args' else return (VPrim n ar args' impl)
    VConF tag c ar args ->
      let args' = args ++ [x]
       in return (if length args' == ar then VCon tag c args' else VConF tag c ar args')
    _ -> throwE (Stuck "applied a non-function")

eval :: Env -> Expr -> Eval Value
eval env = \case
  EVar _ x -> look x
  ECon _ c -> look c
  ELit _ l -> return $ case l of
    LInt n -> VInt n
    LStr s -> VStr s
    LBool b -> VBool b
    LUnit -> VUnit
  EApp _ f a -> do
    fv <- eval env f
    av <- eval env a
    apply fv av
  ELam _ x b -> return (VClo env x b)
  ELet p pat rhs body -> do
    v <- eval env rhs
    case match pat v of
      Just bs -> eval (M.union (M.fromList bs) env) body
      Nothing -> throwE (MatchFail p)
  ELetRec _ binds body -> eval (recEnv env binds) body
  EIf _ c a b ->
    eval env c >>= \case
      VBool True -> eval env a
      VBool False -> eval env b
      _ -> throwE (Stuck "if on a non-boolean")
  EMatch p s arms -> do
    v <- eval env s
    let go [] = throwE (MatchFail p)
        go ((pat, body) : rest) = case match pat v of
          Just bs -> eval (M.union (M.fromList bs) env) body
          Nothing -> go rest
    go arms
  ETuple _ es -> VTup <$> mapM (eval env) es
  ESeq _ a b -> eval env a >> eval env b
  where
    look x = maybe (throwE (Stuck ("unbound " ++ x))) return (M.lookup x env)

recEnv :: Env -> [(Name, Expr)] -> Env
recEnv env binds = env'
  where
    env' = foldr add env binds
    add (n, ELam _ x b) = M.insert n (VClo env' x b)
    add (n, _) = M.insert n (VStr ("<invalid rec " ++ n ++ ">"))

match :: Pat -> Value -> Maybe [(Name, Value)]
match pat v = case (pat, v) of
  (PWild, _) -> Just []
  (PVar "_", _) -> Just []
  (PVar x, _) -> Just [(x, v)]
  (PLit l, _) -> if litEq l v then Just [] else Nothing
  (PTuple ps, VTup vs) | length ps == length vs -> concat <$> zipWithM match ps vs
  (PCon _ c ps, VCon _ c' vs) | c == c' -> concat <$> zipWithM match ps vs
  _ -> Nothing
  where
    litEq (LInt a) (VInt b) = a == b
    litEq (LStr a) (VStr b) = a == b
    litEq (LBool a) (VBool b) = a == b
    litEq LUnit VUnit = True
    litEq _ _ = False

-- ---------------------------------------------------------------------------
-- Declarations

evalDecl :: Env -> Decl -> Eval (Env, [(Name, Value)])
evalDecl env = \case
  DLet p pat rhs -> do
    v <- eval env rhs
    case match pat v of
      Just bs -> return (M.union (M.fromList bs) env, [ b | b@(n, _) <- bs, n /= "_" ])
      Nothing -> throwE (MatchFail p)
  DLetRec _ binds -> do
    let env' = recEnv env binds
    return (env', [ (n, env' M.! n) | (n, _) <- binds ])
  DExpr _ e -> do
    v <- eval env e
    return (env, [("-", v)])
  DData _ _ _ cons ->
    let vals = [ (c, if null args then VCon tag c [] else VConF tag c (length args) []) | (tag, (c, args)) <- zip [0 ..] cons ]
     in return (foldr (uncurry M.insert) env vals, [])

evalExpr :: Env -> Expr -> Eval Value
evalExpr = eval

-- ---------------------------------------------------------------------------
-- Primitives

prim :: Name -> Int -> ([Value] -> Eval Value) -> (Name, Value)
prim n ar f = (n, VPrim n ar [] f)

initialEnv :: Env
initialEnv =
  M.fromList $
    [ arith "+" (+), arith "-" (-), arith "*" (*)
    , prim "/" 2 $ \case [VInt _, VInt 0] -> throwE DivZero; [VInt a, VInt b] -> return (VInt (a `quot` b)); _ -> stuck "/"
    , prim "%" 2 $ \case [VInt _, VInt 0] -> throwE DivZero; [VInt a, VInt b] -> return (VInt (a `rem` b)); _ -> stuck "%"
    , prim "negate" 1 $ \case [VInt a] -> return (VInt (negate a)); _ -> stuck "negate"
    , prim "not" 1 $ \case [VBool b] -> return (VBool (not b)); _ -> stuck "not"
    , prim "^" 2 $ \case [VStr a, VStr b] -> return (VStr (a ++ b)); _ -> stuck "^"
    , cmpOp "==" (== EQ), cmpOp "!=" (/= EQ), cmpOp "<" (== LT), cmpOp "<=" (/= GT), cmpOp ">" (== GT), cmpOp ">=" (/= LT)
    , prim "compare" 2 $ \case [a, b] -> VInt . ordInt <$> compareV a b; _ -> stuck "compare"
    , prim "show" 1 $ \case [v] -> return (VStr (showValue v)); _ -> stuck "show"
    , prim "print" 1 $ \case [VStr s] -> liftIO (putStrLn s >> hFlush stdout) >> return VUnit; _ -> stuck "print"
    , prim "error" 1 $ \case [VStr s] -> throwE (UserError s); _ -> stuck "error"
    , prim "str_len" 1 $ \case [VStr s] -> return (VInt (fromIntegral (length s))); _ -> stuck "str_len"
    , prim "chars" 1 $ \case [VStr s] -> return (foldr (\ch acc -> VCon 1 "Cons" [VStr [ch], acc]) (VCon 0 "Nil" []) s); _ -> stuck "chars"
    , prim "implode" 1 $ \case [v] -> VStr <$> implode v; _ -> stuck "implode"
    ]
  where
    stuck n = throwE (Stuck ("bad arguments to " ++ n))
    arith n f = prim n 2 $ \case [VInt a, VInt b] -> return (VInt (f a b)); _ -> stuck n
    cmpOp n f = prim n 2 $ \case [a, b] -> VBool . f <$> compareV a b; _ -> stuck n
    ordInt = \case LT -> -1; EQ -> 0; GT -> 1
    implode = \case
      VCon _ "Nil" [] -> return ""
      VCon _ "Cons" [VStr s, rest] -> (s ++) <$> implode rest
      _ -> throwE (Stuck "implode")

-- | Structural ordering (like OCaml's polymorphic compare).
compareV :: Value -> Value -> Eval Ordering
compareV a b = case (a, b) of
  (VInt x, VInt y) -> return (compare x y)
  (VStr x, VStr y) -> return (compare x y)
  (VBool x, VBool y) -> return (compare x y)
  (VUnit, VUnit) -> return EQ
  (VTup xs, VTup ys) -> lexi xs ys
  (VCon t1 _ xs, VCon t2 _ ys) -> if t1 /= t2 then return (compare t1 t2) else lexi xs ys
  (f, _) | isFun f -> throwE CompareFun
  (_, g) | isFun g -> throwE CompareFun
  _ -> throwE (Stuck "compared values of different shapes")
  where
    lexi (x : xs) (y : ys) = compareV x y >>= \case EQ -> lexi xs ys; o -> return o
    lexi [] [] = return EQ
    lexi _ _ = throwE (Stuck "compared tuples of different sizes")
    isFun = \case VClo {} -> True; VPrim {} -> True; VConF {} -> True; _ -> False

showValue :: Value -> String
showValue = go 0
  where
    go :: Int -> Value -> String
    go p = \case
      VInt n -> if n < 0 && p > 0 then "(" ++ show n ++ ")" else show n
      VStr s -> show s
      VBool b -> if b then "true" else "false"
      VUnit -> "()"
      VTup vs -> "(" ++ commas (map (go 0) vs) ++ ")"
      v@(VCon _ c args) -> case listElems v of
        Just xs -> "[" ++ commas (map (go 0) xs) ++ "]"
        Nothing
          | null args -> c
          | otherwise -> paren (p > 0) (unwords (c : map (go 1) args))
      VClo {} -> "<fun>"
      VPrim {} -> "<fun>"
      VConF {} -> "<fun>"
    commas = foldr1 (\x acc -> x ++ ", " ++ acc) . orEmpty
    orEmpty [] = [""]
    orEmpty xs = xs
    paren b s = if b then "(" ++ s ++ ")" else s
    listElems = \case
      VCon _ "Nil" [] -> Just []
      VCon _ "Cons" [x, xs] -> (x :) <$> listElems xs
      _ -> Nothing
