{-# LANGUAGE LambdaCase #-}

-- | Hindley-Milner type inference (Algorithm W with a mutable substitution
--   kept in a state monad), let-polymorphism, mutually recursive bindings
--   and user-defined algebraic data types.
module Infer
  ( TEnv (..)
  , ConInfo (..)
  , TypeError (..)
  , initialTEnv
  , inferDecl
  , inferTopExpr
  , siblingsOf
  ) where

import Control.Monad (foldM, forM, forM_, unless, when, zipWithM_)
import Control.Monad.State.Strict
import qualified Data.IntMap.Strict as IM
import Data.List (nub, (\\))
import qualified Data.Map.Strict as M
import Syntax

-- ---------------------------------------------------------------------------
-- Environments

data ConInfo = ConInfo
  { conTypeName :: Name
  , conArity :: !Int
  , conTag :: !Int
  , conScheme :: Scheme
  }

data TEnv = TEnv
  { tVars :: M.Map Name Scheme
  , tCons :: M.Map Name ConInfo
  , tTypes :: M.Map Name (Int, [Name]) -- arity, constructors in order
  , tSupply :: !Int -- fresh variable supply persists across declarations
  }

-- | All constructors (name, arity) of the datatype that @c@ belongs to.
siblingsOf :: TEnv -> Name -> [(Name, Int)]
siblingsOf env c = case M.lookup c (tCons env) of
  Nothing -> []
  Just ci -> case M.lookup (conTypeName ci) (tTypes env) of
    Nothing -> []
    Just (_, cs) -> [ (k, maybe 0 conArity (M.lookup k (tCons env))) | k <- cs ]

data TypeError = TypeError Pos String

-- ---------------------------------------------------------------------------
-- Inference monad

data Err = Mismatch Type Type | Occurs Int Type | Fail Pos String

data St = St { supply :: !Int, subst :: IM.IntMap Type }

newtype Infer a = Infer { unInfer :: St -> Either Err (a, St) }

instance Functor Infer where
  fmap f (Infer g) = Infer $ \s -> fmap (\(a, s') -> (f a, s')) (g s)

instance Applicative Infer where
  pure a = Infer $ \s -> Right (a, s)
  mf <*> ma = do f <- mf; f <$> ma

instance Monad Infer where
  Infer g >>= k = Infer $ \s -> case g s of
    Left e -> Left e
    Right (a, s') -> unInfer (k a) s'

throwI :: Err -> Infer a
throwI e = Infer $ \_ -> Left e

catchI :: Infer a -> (Err -> Infer a) -> Infer a
catchI (Infer g) h = Infer $ \s -> case g s of
  Left e -> unInfer (h e) s
  r -> r

failAt :: Pos -> String -> Infer a
failAt p m = throwI (Fail p m)

fresh :: Infer Type
fresh = Infer $ \s -> Right (TV (supply s), s { supply = supply s + 1 })

-- | Apply the current substitution everywhere (path-compressing as we go).
zonk :: Type -> Infer Type
zonk t = case t of
  TV v -> do
    sub <- Infer $ \s -> Right (subst s, s)
    case IM.lookup v sub of
      Nothing -> return t
      Just t' -> do
        t'' <- zonk t'
        Infer $ \s -> Right ((), s { subst = IM.insert v t'' (subst s) })
        return t''
  TC c ts -> TC c <$> mapM zonk ts
  TFun a b -> TFun <$> zonk a <*> zonk b
  TTup ts -> TTup <$> mapM zonk ts

bindVar :: Int -> Type -> Infer ()
bindVar v t
  | t == TV v = return ()
  | v `elem` ftv t = throwI (Occurs v t)
  | otherwise = Infer $ \s -> Right ((), s { subst = IM.insert v t (subst s) })

unify :: Type -> Type -> Infer ()
unify a b = do
  a' <- zonk a
  b' <- zonk b
  case (a', b') of
    (TV v, t) -> bindVar v t
    (t, TV v) -> bindVar v t
    (TFun x1 y1, TFun x2 y2) -> unify x1 x2 >> unify y1 y2
    (TC c1 as, TC c2 bs) | c1 == c2 && length as == length bs -> zipWithM_ unify as bs
    (TTup as, TTup bs) | length as == length bs -> zipWithM_ unify as bs
    _ -> throwI (Mismatch a' b')

-- | Unify with a human-readable explanation on failure. @mk@ receives the
--   pretty-printed (expected, actual) types after zonking.
unifyMsg :: Pos -> Type -> Type -> (String -> String -> String) -> Infer ()
unifyMsg p expected actual mk =
  unify expected actual `catchI` \case
    Fail q m -> throwI (Fail q m)
    err -> do
      e' <- zonk expected
      a' <- zonk actual
      detail <- case err of
        Mismatch x y -> do
          let [xs, ys, es, as'] = prettyTypes [x, y, e', a']
          return $
            if (xs, ys) == (es, as') || (ys, xs) == (es, as')
              then ""
              else "\n    (cannot match " ++ xs ++ " with " ++ ys ++ ")"
        Occurs v t -> do
          let [vs, ts] = prettyTypes [TV v, t]
          return ("\n    (infinite type: " ++ vs ++ " = " ++ ts ++ ")")
        _ -> return ""
      let [es, as'] = prettyTypes [e', a']
      throwI (Fail p (mk es as' ++ detail))

instantiate :: Scheme -> Infer Type
instantiate (Forall vs t) = do
  fs <- mapM (const fresh) vs
  let m = IM.fromList (zip vs fs)
      go = \case
        TV v -> IM.findWithDefault (TV v) v m
        TC c ts -> TC c (map go ts)
        TFun a b -> TFun (go a) (go b)
        TTup ts -> TTup (map go ts)
  return (go t)

envFtv :: M.Map Name Scheme -> Infer [Int]
envFtv vars = nub . concat <$> forM (M.elems vars) (\(Forall vs t) -> if null (ftv t) then return [] else (\t' -> ftv t' \\ vs) <$> zonk t)

generalize :: M.Map Name Scheme -> Type -> Infer Scheme
generalize vars t = do
  t' <- zonk t
  if null (ftv t')
    then return (Forall [] t')
    else do
      fe <- envFtv vars
      return (Forall (ftv t' \\ fe) t')

mono :: Type -> Scheme
mono = Forall []

-- ---------------------------------------------------------------------------
-- Expressions

litType :: Lit -> Type
litType = \case
  LInt _ -> tInt
  LStr _ -> tStr
  LBool _ -> tBool
  LUnit -> tUnit

infer :: TEnv -> Expr -> Infer Type
infer env = \case
  EVar p x -> case M.lookup x (tVars env) of
    Just s -> instantiate s
    Nothing -> failAt p ("unbound variable '" ++ x ++ "'")
  ECon p c -> case M.lookup c (tCons env) of
    Just ci -> instantiate (conScheme ci)
    Nothing -> failAt p ("unknown constructor '" ++ c ++ "'")
  ELit _ l -> return (litType l)
  EApp p f a -> do
    tf <- infer env f >>= zonk
    case tf of
      TFun targ tres -> do
        ta <- infer env a
        unifyMsg (exprPos a) targ ta $ \ex got ->
          "this argument has type " ++ got ++ " but the function expects " ++ ex
        return tres
      TV _ -> do
        ta <- infer env a
        r <- fresh
        unifyMsg p tf (TFun ta r) $ \ex got -> "this expression has type " ++ ex ++ " but is applied as a function of type " ++ got
        return r
      _ -> do
        let [s] = prettyTypes [tf]
        failAt p ("this expression has type " ++ s ++ "; it is not a function and cannot be applied")
  ELam _ x body -> do
    tv <- fresh
    tb <- infer (bindMono x tv env) body
    return (TFun tv tb)
  ELet _ pat rhs body -> do
    env' <- inferBinding env pat rhs
    infer env' body
  ELetRec p binds body -> do
    env' <- inferRec env p binds
    infer env' body
  EIf _ c a b -> do
    tc <- infer env c
    unifyMsg (exprPos c) tBool tc $ \_ got -> "the condition of an 'if' must be Bool, but it has type " ++ got
    ta <- infer env a
    tb <- infer env b
    unifyMsg (exprPos b) ta tb $ \ex got -> "the 'else' branch has type " ++ got ++ " but the 'then' branch has type " ++ ex
    return ta
  EMatch _ scrut arms -> do
    ts <- infer env scrut
    r <- fresh
    forM_ (zip [1 :: Int ..] arms) $ \(i, (pat, body)) -> do
      (tp, binds) <- inferPat env (exprPos scrut) pat
      unifyMsg (patPos (exprPos body) pat) ts tp $ \ex got ->
        "this pattern matches values of type " ++ got ++ " but the scrutinee has type " ++ ex
      tb <- infer (foldr (\(n, t) -> bindMono n t) env binds) body
      unifyMsg (exprPos body) r tb $ \ex got ->
        if i == 1 then "impossible" else "this match arm has type " ++ got ++ " but earlier arms have type " ++ ex
    return r
  ETuple _ es -> TTup <$> mapM (infer env) es
  ESeq _ a b -> do
    ta <- infer env a
    unifyMsg (exprPos a) tUnit ta $ \_ got -> "the left side of ';' should have type Unit, but it has type " ++ got
    infer env b

patPos :: Pos -> Pat -> Pos
patPos dflt = \case
  PCon p _ _ -> p
  _ -> dflt

bindMono :: Name -> Type -> TEnv -> TEnv
bindMono "_" _ env = env
bindMono x t env = env { tVars = M.insert x (mono t) (tVars env) }

bindScheme :: Name -> Scheme -> TEnv -> TEnv
bindScheme "_" _ env = env
bindScheme x s env = env { tVars = M.insert x s (tVars env) }

-- | Non-recursive let. Each variable bound by the pattern is generalised
--   independently (as Haskell does for pattern bindings).
inferBinding :: TEnv -> Pat -> Expr -> Infer TEnv
inferBinding env pat rhs = do
  t <- infer env rhs
  case pat of
    PVar x -> do
      s <- generalize (tVars env) t
      return (bindScheme x s env)
    _ -> do
      (tp, binds) <- inferPat env (exprPos rhs) pat
      unifyMsg (patPos (exprPos rhs) pat) tp t $ \ex got ->
        "this value has type " ++ got ++ " but the pattern expects " ++ ex
      foldM (\e (n, tn) -> do s <- generalize (tVars env) tn; return (bindScheme n s e)) env binds

inferRec :: TEnv -> Pos -> [(Name, Expr)] -> Infer TEnv
inferRec env p binds = do
  let names = map fst binds
  when (length (nub names) /= length names) $ failAt p "a name is bound twice in the same 'let rec'"
  forM_ binds $ \(n, rhs) -> case rhs of
    ELam {} -> return ()
    _ -> failAt (exprPos rhs) ("'let rec' can only define functions, but '" ++ n ++ "' is not one")
  tvs <- mapM (const fresh) binds
  let env1 = foldr (uncurry bindMono) env (zip names tvs)
  forM_ (zip binds tvs) $ \((n, rhs), tv) -> do
    t <- infer env1 rhs
    unifyMsg (exprPos rhs) tv t $ \ex got ->
      "'" ++ n ++ "' is used with type " ++ ex ++ " but defined with type " ++ got
  schemes <- mapM (generalize (tVars env)) tvs
  return (foldr (uncurry bindScheme) env (zip names schemes))

-- ---------------------------------------------------------------------------
-- Patterns

inferPat :: TEnv -> Pos -> Pat -> Infer (Type, [(Name, Type)])
inferPat env p0 pat0 = do
  (t, bs) <- go p0 pat0
  let names = map fst bs
      dups = names \\ nub names
  unless (null dups) $ failAt p0 ("variable '" ++ head dups ++ "' is bound more than once in this pattern")
  return (t, bs)
  where
    go p = \case
      PWild -> (\t -> (t, [])) <$> fresh
      PVar x -> (\t -> (t, [(x, t)])) <$> fresh
      PLit l -> return (litType l, [])
      PTuple ps -> do
        rs <- mapM (go p) ps
        return (TTup (map fst rs), concatMap snd rs)
      PCon q c args -> case M.lookup c (tCons env) of
        Nothing -> failAt q ("unknown constructor '" ++ c ++ "'")
        Just ci -> do
          when (conArity ci /= length args) $
            failAt q ("constructor '" ++ c ++ "' expects " ++ plural (conArity ci) "argument" ++ " but the pattern gives " ++ show (length args))
          t <- instantiate (conScheme ci)
          let (argTys, res) = splitFun (conArity ci) t
          rs <- mapM (go q) args
          zipWithM_ (\(ta, _) want -> unifyMsg q want ta $ \ex got -> "a sub-pattern of '" ++ c ++ "' has type " ++ got ++ " but should have type " ++ ex) rs argTys
          return (res, concatMap snd rs)

splitFun :: Int -> Type -> ([Type], Type)
splitFun 0 t = ([], t)
splitFun n (TFun a b) = let (as, r) = splitFun (n - 1) b in (a : as, r)
splitFun _ t = ([], t)

plural :: Int -> String -> String
plural 1 w = "1 " ++ w
plural n w = show n ++ " " ++ w ++ "s"

-- ---------------------------------------------------------------------------
-- Declarations

-- | Run an inference action against an environment, threading its supply.
runIn :: TEnv -> Infer a -> Either TypeError (a, TEnv -> TEnv)
runIn env m = case unInfer m (St (tSupply env) IM.empty) of
  Left (Fail p msg) -> Left (TypeError p msg)
  Left _ -> Left (TypeError noPos "internal error: unexpected unification failure")
  Right (a, st) -> Right (a, \e -> e { tSupply = supply st })

-- | Type-check one declaration. Returns the new environment and the
--   schemes of the names it introduced (for display).
inferDecl :: TEnv -> Decl -> Either TypeError (TEnv, [(Name, Scheme)])
inferDecl env d = do
  ((env', shown), fixSupply) <- runIn env (go d)
  return (fixSupply env', shown)
  where
    go = \case
      DLet _ pat rhs -> do
        env' <- inferBinding env pat rhs
        return (env', [ (n, tVars env' M.! n) | n <- patVars pat, n /= "_" ])
      DLetRec p binds -> do
        env' <- inferRec env p binds
        return (env', [ (n, tVars env' M.! n) | (n, _) <- binds ])
      DExpr _ e -> do
        t <- infer env e
        s <- generalize (tVars env) t
        return (env, [("-", s)])
      DData p name params cons -> dataDecl p name params cons

    dataDecl p name params cons = do
      when (M.member name (tTypes env)) $ failAt p ("type '" ++ name ++ "' is already defined")
      when (length (nub params) /= length params) $ failAt p "duplicate type parameter"
      let cnames = map fst cons
      forM_ cnames $ \c -> when (M.member c (tCons env)) $ failAt p ("constructor '" ++ c ++ "' is already defined")
      when (length (nub cnames) /= length cnames) $ failAt p "duplicate constructor name"
      pvs <- mapM (const fresh) params
      let pmap = zip params pvs
          types' = M.insert name (length params, cnames) (tTypes env)
          resTy = TC name pvs
          ids = [ v | TV v <- pvs ]
          conv = \case
            TyVar v -> maybe (failAt p ("type variable '" ++ v ++ "' is not a parameter of '" ++ name ++ "'")) return (lookup v pmap)
            TyFun a b -> TFun <$> conv a <*> conv b
            TyTuple ts -> TTup <$> mapM conv ts
            TyCon c args -> case M.lookup c types' of
              Nothing -> failAt p ("unknown type '" ++ c ++ "'")
              Just (ar, _) -> do
                when (ar /= length args) $ failAt p ("type '" ++ c ++ "' expects " ++ plural ar "argument" ++ " but is given " ++ show (length args))
                TC c <$> mapM conv args
      infos <- forM (zip [0 ..] cons) $ \(tag, (c, args)) -> do
        argTys <- mapM conv args
        let sch = Forall ids (foldr TFun resTy argTys)
        return (c, ConInfo name (length args) tag sch)
      let env' = env { tTypes = types', tCons = foldr (uncurry M.insert) (tCons env) infos }
      return (env', [ (c, conScheme ci) | (c, ci) <- infos ])

patVars :: Pat -> [Name]
patVars = \case
  PVar x -> [x]
  PTuple ps -> concatMap patVars ps
  PCon _ _ ps -> concatMap patVars ps
  _ -> []

inferTopExpr :: TEnv -> Expr -> Either TypeError Scheme
inferTopExpr env e = fst <$> runIn env (infer env e >>= generalize (tVars env))

-- ---------------------------------------------------------------------------
-- Built-in environment (primitive operators; List/Option etc. come from the prelude)

initialTEnv :: TEnv
initialTEnv =
  TEnv
    { tVars = M.fromList prims
    , tCons = M.empty
    , tTypes = M.fromList [("Int", (0, [])), ("Bool", (0, [])), ("String", (0, [])), ("Unit", (0, []))]
    , tSupply = 0
    }
  where
    a = TV (-1)
    poly = Forall [-1]
    arith = mono (TFun tInt (TFun tInt tInt))
    cmp = poly (TFun a (TFun a tBool))
    prims =
      [ (op, arith) | op <- ["+", "-", "*", "/", "%"] ]
        ++ [ (op, cmp) | op <- ["==", "!=", "<", "<=", ">", ">="] ]
        ++ [ ("^", mono (TFun tStr (TFun tStr tStr)))
           , ("negate", mono (TFun tInt tInt))
           , ("not", mono (TFun tBool tBool))
           , ("show", poly (TFun a tStr))
           , ("print", mono (TFun tStr tUnit))
           , ("error", poly (TFun tStr a))
           , ("str_len", mono (TFun tStr tInt))
           , ("chars", mono (TFun tStr (tList tStr)))
           , ("implode", mono (TFun (tList tStr) tStr))
           , ("compare", poly (TFun a (TFun a tInt)))
           ]
