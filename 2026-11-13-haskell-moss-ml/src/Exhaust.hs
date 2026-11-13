{-# LANGUAGE LambdaCase #-}

-- | Pattern-match analysis after Maranget, "Warnings for pattern matching"
--   (JFP 2007). We compute the *usefulness* predicate on pattern matrices,
--   which yields both redundancy warnings and a concrete witness value for
--   every non-exhaustive match.
module Exhaust (Warning (..), checkDecl, showWarning) where

import Data.List (intercalate)
import Data.Maybe (listToMaybe, mapMaybe)
import Syntax

data Warning
  = NonExhaustive Pos String -- an example value that is not matched
  | Redundant Pos Int -- arm index (1-based) that can never match

showWarning :: Warning -> String
showWarning = \case
  NonExhaustive p w -> show p ++ ": warning: this match is not exhaustive; for example, this value is not matched:\n    " ++ w
  Redundant p i -> show p ++ ": warning: match arm " ++ show i ++ " is unreachable (earlier arms cover it)"

-- Simplified patterns ----------------------------------------------------------

data Head = HCon Name Int | HTup Int | HLit Lit deriving (Eq, Show)

data SP = SWild | SCon Head [SP]

arity :: Head -> Int
arity = \case
  HCon _ n -> n
  HTup n -> n
  HLit _ -> 0

simplify :: Pat -> SP
simplify = \case
  PWild -> SWild
  PVar _ -> SWild
  PLit LUnit -> SWild -- unit has exactly one value
  PLit l -> SCon (HLit l) []
  PTuple ps -> SCon (HTup (length ps)) (map simplify ps)
  PCon _ c ps -> SCon (HCon c (length ps)) (map simplify ps)

type Siblings = Name -> [(Name, Int)]

-- | The complete signature a head belongs to, or Nothing if it is infinite.
signature :: Siblings -> Head -> Maybe [Head]
signature sib = \case
  HCon c _ -> Just [ HCon k n | (k, n) <- sib c ]
  HTup n -> Just [HTup n]
  HLit (LBool _) -> Just [HLit (LBool False), HLit (LBool True)]
  HLit _ -> Nothing

headsOf :: [[SP]] -> [Head]
headsOf rows = dedup [ h | (SCon h _ : _) <- rows ]
  where
    dedup = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

-- | Rows whose first column can match head @h@, with that column expanded.
specialize :: Head -> [[SP]] -> [[SP]]
specialize h = mapMaybe $ \case
  SWild : rest -> Just (replicate (arity h) SWild ++ rest)
  SCon h' args : rest | h' == h -> Just (args ++ rest)
  _ -> Nothing

defaultMatrix :: [[SP]] -> [[SP]]
defaultMatrix = mapMaybe $ \case
  SWild : rest -> Just rest
  _ -> Nothing

complete :: Siblings -> [Head] -> Maybe [Head]
complete _ [] = Nothing
complete sib hs@(h : _) = case signature sib h of
  Just sig | all (`elem` hs) sig -> Just sig
  _ -> Nothing

-- | Is pattern vector @q@ useful with respect to the rows (does it match
--   some value that no row matches)?
useful :: Siblings -> [[SP]] -> [SP] -> Bool
useful _ [] _ = True
useful _ _ [] = False
useful sib rows (q : qs) = case q of
  SCon h args -> useful sib (specialize h rows) (args ++ qs)
  SWild -> case complete sib (headsOf rows) of
    Just sig -> any (\h -> useful sib (specialize h rows) (replicate (arity h) SWild ++ qs)) sig
    Nothing -> useful sib (defaultMatrix rows) qs

-- | A vector of @n@ patterns describing values not matched by any row.
witness :: Siblings -> [[SP]] -> Int -> Maybe [SP]
witness _ [] n = Just (replicate n SWild)
witness _ _ 0 = Nothing
witness sib rows n =
  let hs = headsOf rows
   in case complete sib hs of
        Just sig ->
          listToMaybe
            [ rebuild h w
            | h <- sig
            , Just w <- [witness sib (specialize h rows) (arity h + n - 1)]
            ]
        Nothing -> do
          w <- witness sib (defaultMatrix rows) (n - 1)
          return (missing hs : w)
  where
    rebuild h w = let (args, rest) = splitAt (arity h) w in SCon h args : rest
    missing [] = SWild
    missing hs@(h : _) = case signature sib h of
      Just sig -> case filter (`notElem` hs) sig of
        (m : _) -> SCon m (replicate (arity m) SWild)
        [] -> SWild
      Nothing -> case h of
        HLit (LInt _) -> SCon (HLit (LInt (head [ i | i <- [0 ..], HLit (LInt i) `notElem` hs ]))) []
        HLit (LStr _) -> SCon (HLit (LStr (head [ s | s <- map (\i -> replicate i 'a') [0 ..], HLit (LStr s) `notElem` hs ]))) []
        _ -> SWild

render :: SP -> String
render = go 0
  where
    go :: Int -> SP -> String
    go _ SWild = "_"
    go _ (SCon (HLit l) _) = case l of
      LInt i -> show i
      LStr s -> show s
      LBool b -> if b then "true" else "false"
      LUnit -> "()"
    go _ (SCon (HTup _) ps) = "(" ++ intercalate ", " (map (go 0) ps) ++ ")"
    go _ (SCon (HCon "Nil" 0) []) = "[]"
    go p (SCon (HCon "Cons" 2) [x, xs]) = paren (p > 0) (go 1 x ++ " :: " ++ go 0 xs)
    go _ (SCon (HCon c _) []) = c
    go p (SCon (HCon c _) ps) = paren (p > 0) (unwords (c : map (go 1) ps))
    paren b s = if b then "(" ++ s ++ ")" else s

-- Walking the program ----------------------------------------------------------

checkMatch :: Siblings -> Pos -> [Pat] -> [Warning]
checkMatch sib p pats =
  let rows = map ((: []) . simplify) pats
      redundant =
        [ Redundant p i
        | (i, r) <- zip [1 ..] rows
        , not (useful sib (take (i - 1) rows) r)
        ]
      nonEx = case witness sib rows 1 of
        Just [w] -> [NonExhaustive p (render w)]
        _ -> []
   in nonEx ++ redundant

checkExpr :: Siblings -> Expr -> [Warning]
checkExpr sib = go
  where
    go = \case
      EVar {} -> []
      ECon {} -> []
      ELit {} -> []
      EApp _ f a -> go f ++ go a
      ELam _ _ b -> go b
      ELet p pat rhs body -> letPat p pat ++ go rhs ++ go body
      ELetRec _ bs body -> concatMap (go . snd) bs ++ go body
      EIf _ c a b -> go c ++ go a ++ go b
      EMatch p s arms -> checkMatch sib p (map fst arms) ++ go s ++ concatMap (go . snd) arms
      ETuple _ es -> concatMap go es
      ESeq _ a b -> go a ++ go b
    letPat p pat = case pat of
      PVar _ -> []
      _ -> checkMatch sib p [pat]

checkDecl :: Siblings -> Decl -> [Warning]
checkDecl sib = \case
  DLet p pat rhs -> (case pat of PVar _ -> []; _ -> checkMatch sib p [pat]) ++ checkExpr sib rhs
  DLetRec _ bs -> concatMap (checkExpr sib . snd) bs
  DExpr _ e -> checkExpr sib e
  DData {} -> []
