{-# LANGUAGE LambdaCase #-}

-- | Empirical soundness testing. We generate random, *untyped* programs,
--   let the type checker accept or reject them, run the accepted ones and
--   check three theorems:
--
--   1. Progress: a well-typed program never gets stuck (no "applied a
--      non-function", "if on a non-boolean", ...).
--   2. Preservation: the final value inhabits the inferred type.
--   3. Exhaustiveness: if the checker reported no non-exhaustive match,
--      no match can fail at run time.
module Fuzz (fuzzMain) where

import Control.Monad (forM_, replicateM, when)
import Control.Monad.State.Strict
import Data.Bits (shiftR, xor)
import qualified Data.Map.Strict as M
import Data.Word (Word64)
import Eval
import Exhaust
import Infer
import Syntax
import System.Exit (exitFailure)
import System.IO

-- SplitMix64 ------------------------------------------------------------------

data GS = GS { seed :: !Word64, counter :: !Int }

type G = State GS

next64 :: G Word64
next64 = do
  s <- get
  let z0 = seed s + 0x9E3779B97F4A7C15
      z1 = (z0 `xor` (z0 `shiftR` 30)) * 0xBF58476D1CE4E5B9
      z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94D049BB133111EB
  put s { seed = z0 }
  return (z2 `xor` (z2 `shiftR` 31))

roll :: Int -> G Int
roll n = (\w -> fromIntegral (w `mod` fromIntegral n)) <$> next64

pick :: [a] -> G a
pick xs = (xs !!) <$> roll (length xs)

freq :: [(Int, G a)] -> G a
freq opts = do
  r <- roll (sum (map fst opts))
  let go k ((w, g) : rest) = if k < w then g else go (k - w) rest
      go _ [] = error "freq"
  go r opts

newVar :: G Name
newVar = do
  s <- get
  put s { counter = counter s + 1 }
  return ("v" ++ show (counter s))

-- Program generator -------------------------------------------------------------

p0 :: Pos
p0 = noPos

app :: Expr -> Expr -> Expr
app = EApp p0

library :: [Name]
library = ["map", "filter", "foldl", "foldr", "length", "fst", "snd", "id", "reverse", "append", "sum", "not", "show", "range", "zip", "find", "with_default", "sort", "compose", "const"]

genExpr :: [Name] -> Int -> G Expr
genExpr scope d
  | d <= 0 = leaf
  | otherwise =
      freq
        [ (3, leaf)
        , (6, app <$> sub <*> sub)
        , (6, do op <- pick ["+", "-", "*", "/", "==", "<", "^"]; a <- sub; b <- sub; return (app (app (EVar p0 op) a) b))
        , (3, do a <- sub; b <- sub; return (app (app (ECon p0 "Cons") a) b))
        , (2, app (ECon p0 "Some") <$> sub)
        , (5, do x <- newVar; ELam p0 x <$> genExpr (x : scope) (d - 1))
        , (4, do x <- newVar; e1 <- sub; ELet p0 (PVar x) e1 <$> genExpr (x : scope) (d - 1))
        , (2, do (pat, vs) <- genPat 2; e1 <- sub; ELet p0 pat e1 <$> genExpr (vs ++ scope) (d - 1))
        , (3, do
              f <- newVar; x <- newVar
              body <- genExpr (f : x : scope) (d - 1)
              ELetRec p0 [(f, ELam p0 x body)] <$> genExpr (f : scope) (d - 1))
        , (3, EIf p0 <$> sub <*> sub <*> sub)
        , (2, do a <- sub; b <- sub; return (ETuple p0 [a, b]))
        , (5, do
              s <- sub
              n <- (+ 1) <$> roll 3
              fam <- roll 6
              arms <- replicateM n $ do
                (pat, vs) <- genPatOf fam 3
                body <- genExpr (vs ++ scope) (d - 1)
                return (pat, body)
              return (EMatch p0 s arms))
        ]
  where
    sub = genExpr scope (d - 1)
    leaf =
      freq $
        [ (3, ELit p0 . LInt . fromIntegral <$> roll 4)
        , (2, ELit p0 . LBool . (== 0) <$> roll 2)
        , (1, ELit p0 . LStr <$> pick ["", "a", "bc"])
        , (1, return (ELit p0 LUnit))
        , (2, ECon p0 <$> pick ["Nil", "None"])
        , (3, EVar p0 <$> pick library)
        ]
          ++ [ (10, EVar p0 <$> pick scope) | not (null scope) ]

-- | Patterns drawn from one "family" so that all arms of a match tend to
--   agree on a type; this makes well-typed matches (and thus interesting
--   exhaustiveness questions) far more common than fully random patterns.
genPatOf :: Int -> Int -> G (Pat, [Name])
genPatOf fam d = case fam of
  0 -> freq [(4, (\b -> (PLit (LBool (b == 0)), [])) <$> roll 2), (1, genPat 0)]
  1 -> freq [(4, (\i -> (PLit (LInt (fromIntegral i)), [])) <$> roll 3), (1, genPat 0)]
  2 | d > 0 -> freq [(3, return (PCon p0 "Nil" [], [])), (4, do (a, va) <- genPat (d - 1); (b, vb) <- genPatOf 2 (d - 1); return (PCon p0 "Cons" [a, b], va ++ vb)), (1, genPat 0)]
  3 | d > 0 -> freq [(3, return (PCon p0 "None" [], [])), (4, do (a, va) <- genPat (d - 1); return (PCon p0 "Some" [a], va)), (1, genPat 0)]
  4 | d > 0 -> do
    f1 <- roll 4
    f2 <- roll 4
    (a, va) <- genPatOf f1 (d - 1)
    (b, vb) <- genPatOf f2 (d - 1)
    return (PTuple [a, b], va ++ vb)
  _ -> genPat d

genPat :: Int -> G (Pat, [Name])
genPat d =
  freq $
    [ (3, return (PWild, []))
    , (3, (\x -> (PVar x, [x])) <$> newVar)
    , (2, (\i -> (PLit (LInt (fromIntegral i)), [])) <$> roll 3)
    , (1, (\b -> (PLit (LBool (b == 0)), [])) <$> roll 2)
    , (2, return (PCon p0 "Nil" [], []))
    , (1, return (PCon p0 "None" [], []))
    ]
      ++ if d <= 0
        then []
        else
          [ (3, do (a, va) <- genPat (d - 1); (b, vb) <- genPat (d - 1); return (PCon p0 "Cons" [a, b], va ++ vb))
          , (2, do (a, va) <- genPat (d - 1); return (PCon p0 "Some" [a], va))
          , (2, do (a, va) <- genPat (d - 1); (b, vb) <- genPat (d - 1); return (PTuple [a, b], va ++ vb))
          ]

-- Checking ------------------------------------------------------------------------

-- | Does the value inhabit the type? (Type variables accept anything.)
conforms :: TEnv -> Type -> Value -> Bool
conforms env ty v = case (ty, v) of
  (TV _, _) -> True
  (TC "Int" [], VInt _) -> True
  (TC "Bool" [], VBool _) -> True
  (TC "String" [], VStr _) -> True
  (TC "Unit" [], VUnit) -> True
  (TTup ts, VTup vs) -> length ts == length vs && and (zipWith (conforms env) ts vs)
  (TFun _ _, f) -> isFun f
  (TC tname targs, VCon _ c args) -> case M.lookup c (tCons env) of
    Just ci | conTypeName ci == tname, Forall ids t <- conScheme ci ->
      let s = M.fromList (zip ids targs)
          argTys = take (conArity ci) (params (substT s t))
       in length argTys == length args && and (zipWith (conforms env) argTys args)
    _ -> False
  _ -> False
  where
    isFun = \case VClo {} -> True; VPrim {} -> True; VConF {} -> True; _ -> False
    params (TFun a b) = a : params b
    params _ = []
    substT s = \case
      TV i -> M.findWithDefault (TV i) i s
      TC c ts -> TC c (map (substT s) ts)
      TFun a b -> TFun (substT s a) (substT s b)
      TTup ts -> TTup (map (substT s) ts)

data Tally = Tally { rejected, values, userErrs, matchFails, fuel, violations :: !Int }

fuzzMain :: TEnv -> Env -> Int -> Int -> IO ()
fuzzMain tenv env n s0 = do
  hSetBuffering stdout NoBuffering
  let go :: Int -> GS -> Tally -> IO Tally
      go i gs t
        | i >= n = return t
        | otherwise = do
            let (prog, gs') = runState (do sz <- (+ 2) <$> roll 5; genExpr [] sz) gs
            t' <- case inferTopExpr tenv prog of
              Left _ -> return t { rejected = rejected t + 1 }
              Right (Forall _ ty) -> do
                let ws = checkDecl (siblingsOf tenv) (DExpr p0 prog)
                    exhaustive = null [ () | NonExhaustive {} <- ws ]
                (r, _) <- runEval 20000 (evalExpr env prog)
                let bad why = do
                      putStrLn ("VIOLATION (" ++ why ++ ") in program #" ++ show i ++ " : " ++ prettyType ty)
                      print prog
                      return t { violations = violations t + 1 }
                case r of
                  Right v
                    | conforms tenv ty v -> return t { values = values t + 1 }
                    | otherwise -> bad ("value " ++ showValue v ++ " does not have its inferred type")
                  Left (Stuck m) -> bad ("stuck: " ++ m)
                  Left (MatchFail _)
                    | exhaustive -> bad "match failed although the checker proved it exhaustive"
                    | otherwise -> return t { matchFails = matchFails t + 1 }
                  Left OutOfFuel -> return t { fuel = fuel t + 1 }
                  Left _ -> return t { userErrs = userErrs t + 1 }
            when ((i + 1) `mod` 10000 == 0) $ putStrLn ("  ... " ++ show (i + 1) ++ " programs")
            go (i + 1) gs' t'
  t <- go 0 (GS (fromIntegral s0) 0) (Tally 0 0 0 0 0 0)
  let typed = n - rejected t
      pct k = show (fromIntegral (round (1000 * fromIntegral k / fromIntegral (max 1 n) :: Double)) / 10 :: Double) ++ "%"
  putStrLn ("random programs generated : " ++ show n)
  putStrLn ("rejected by type checker  : " ++ show (rejected t) ++ " (" ++ pct (rejected t) ++ ")")
  putStrLn ("well-typed, then run      : " ++ show typed)
  forM_
    [ ("  produced a value of the inferred type", values t)
    , ("  raised a runtime error (div by 0, error, compare <fun>)", userErrs t)
    , ("  match failure (checker had warned)", matchFails t)
    , ("  out of fuel (diverging)", fuel t)
    , ("  SOUNDNESS VIOLATIONS", violations t)
    ]
    $ \(label, k) -> putStrLn (label ++ " : " ++ show k)
  when (violations t > 0) exitFailure
