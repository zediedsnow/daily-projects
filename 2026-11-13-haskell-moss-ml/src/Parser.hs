-- | Recursive-descent parser with precedence climbing for binary operators.
module Parser (parseProgram, parseReplLine) where

import Control.Monad (when)
import Lexer
import Syntax

-- ---------------------------------------------------------------------------
-- Parser monad

data PState = PState { toks :: [(Pos, Token)], uniq :: !Int }

newtype P a = P { runP :: PState -> Either (Pos, String) (a, PState) }

instance Functor P where
  fmap f (P g) = P $ \s -> case g s of
    Left e -> Left e
    Right (a, s') -> Right (f a, s')

instance Applicative P where
  pure a = P $ \s -> Right (a, s)
  pf <*> pa = do f <- pf; f <$> pa

instance Monad P where
  P g >>= k = P $ \s -> case g s of
    Left e -> Left e
    Right (a, s') -> runP (k a) s'

peek :: P (Pos, Token)
peek = P $ \s -> Right (head (toks s), s)

peek2 :: P Token
peek2 = P $ \s -> Right (case toks s of (_ : (_, t) : _) -> t; _ -> TEOF, s)

advance :: P (Pos, Token)
advance = P $ \s -> case toks s of
  [t] -> Right (t, s)
  (t : ts) -> Right (t, s { toks = ts })
  [] -> error "empty token stream"

failAt :: Pos -> String -> P a
failAt p msg = P $ \_ -> Left (p, msg)

freshName :: P Name
freshName = P $ \s -> Right ("$p" ++ show (uniq s), s { uniq = uniq s + 1 })

describe :: Token -> String
describe t = case t of
  TInt n -> "integer " ++ show n
  TStr s -> "string " ++ show s
  TLower n -> "identifier '" ++ n ++ "'"
  TUpper n -> "constructor '" ++ n ++ "'"
  TKw k -> "keyword '" ++ k ++ "'"
  TSym s -> "'" ++ s ++ "'"
  TEOF -> "end of input"

expect :: Token -> P Pos
expect want = do
  (p, t) <- peek
  if t == want then advance >> return p else failAt p ("expected " ++ describe want ++ " but found " ++ describe t)

isTok :: Token -> P Bool
isTok t = (== t) . snd <$> peek

optional' :: Token -> P Bool
optional' t = do b <- isTok t; when b (() <$ advance); return b

lowerName :: P (Pos, Name)
lowerName = do
  (p, t) <- peek
  case t of
    TLower n -> advance >> return (p, n)
    _ -> failAt p ("expected an identifier but found " ++ describe t)

-- ---------------------------------------------------------------------------
-- Entry points

parseProgram :: String -> Either (Pos, String) [Decl]
parseProgram src = do
  ts <- lexMoss src
  fst <$> runP decls (PState ts 0)
  where
    decls = do
      (_, t) <- peek
      if t == TEOF then return [] else (:) <$> decl <*> decls

-- | A REPL line is either a declaration or a bare expression.
parseReplLine :: String -> Either (Pos, String) [Decl]
parseReplLine src = do
  ts <- lexMoss src
  fst <$> runP line (PState ts 0)
  where
    line = do
      (p, t) <- peek
      ds <- case t of
        TKw "data" -> (: []) <$> decl
        TKw "let" -> do
          -- `let x = 1 in x + 1` is an expression, `let x = 1` a declaration
          d <- decl
          (_, t') <- peek
          if t' == TKw "in" then failAt p "use the expression form without `in` at top level, or wrap it in parentheses" else return [d]
        _ -> (\e -> [DExpr p e]) <$> expr
      _ <- expect TEOF
      return ds

-- ---------------------------------------------------------------------------
-- Declarations

decl :: P Decl
decl = do
  (p, t) <- peek
  case t of
    TKw "data" -> advance >> dataDecl p
    TKw "let" -> do
      _ <- advance
      isRec <- optional' (TKw "rec")
      if isRec
        then DLetRec p <$> recBindings
        else do (pat, rhs) <- binding; return (DLet p pat rhs)
    _ -> failAt p ("expected a declaration ('let' or 'data') but found " ++ describe t)

dataDecl :: Pos -> P Decl
dataDecl p = do
  (pn, tn) <- peek
  name <- case tn of
    TUpper n -> advance >> return n
    _ -> failAt pn "expected a type name (capitalised) after 'data'"
  params <- manyWhile isLowerTok (snd <$> lowerName)
  _ <- expect (TSym "=")
  _ <- optional' (TSym "|")
  first <- conDef
  rest <- manyWhile (== TSym "|") (advance >> conDef)
  return (DData p name params (first : rest))
  where
    isLowerTok (TLower _) = True
    isLowerTok _ = False
    conDef = do
      (pc, t) <- peek
      case t of
        TUpper c -> do
          _ <- advance
          args <- manyWhile startsTyAtom tyAtom
          return (c, args)
        _ -> failAt pc ("expected a constructor name but found " ++ describe t)

manyWhile :: (Token -> Bool) -> P a -> P [a]
manyWhile ok p = do
  (_, t) <- peek
  if ok t then (:) <$> p <*> manyWhile ok p else return []

-- Types ----------------------------------------------------------------------

startsTyAtom :: Token -> Bool
startsTyAtom t = case t of
  TLower _ -> True; TUpper _ -> True; TSym "(" -> True; _ -> False

tyExpr :: P TyExpr
tyExpr = do
  a <- tyApp
  isArrow <- optional' (TSym "->")
  if isArrow then TyFun a <$> tyExpr else return a

tyApp :: P TyExpr
tyApp = do
  (_, t) <- peek
  case t of
    TUpper c -> do _ <- advance; TyCon c <$> manyWhile startsTyAtom tyAtom
    _ -> tyAtom

tyAtom :: P TyExpr
tyAtom = do
  (p, t) <- advance
  case t of
    TLower v -> return (TyVar v)
    TUpper c -> return (TyCon c [])
    TSym "(" -> do
      first <- tyExpr
      more <- manyWhile (== TSym ",") (advance >> tyExpr)
      _ <- expect (TSym ")")
      return (if null more then first else TyTuple (first : more))
    _ -> failAt p ("expected a type but found " ++ describe t)

-- Bindings -------------------------------------------------------------------

-- | `f p1 p2 = e`  or  `pat = e`
binding :: P (Pat, Expr)
binding = do
  (p, t) <- peek
  case t of
    TLower n -> do
      _ <- advance
      params <- manyWhile startsAtomPat atomPat
      _ <- expect (TSym "=")
      body <- expr
      rhs <- lambdas p params body
      return (PVar n, rhs)
    _ -> do
      pat <- pattern
      _ <- expect (TSym "=")
      rhs <- expr
      return (pat, rhs)

recBindings :: P [(Name, Expr)]
recBindings = do
  b <- one
  rest <- manyWhile (== TKw "and") (advance >> one)
  return (b : rest)
  where
    one = do
      (p, n) <- lowerName
      params <- manyWhile startsAtomPat atomPat
      _ <- expect (TSym "=")
      body <- expr
      rhs <- lambdas p params body
      return (n, rhs)

-- | Desugar `fun p1 p2 -> body` into single-argument lambdas; non-variable
--   parameter patterns become a match on a fresh variable.
lambdas :: Pos -> [Pat] -> Expr -> P Expr
lambdas _ [] body = return body
lambdas p (pat : rest) body = do
  inner <- lambdas p rest body
  case pat of
    PVar x -> return (ELam p x inner)
    PWild -> return (ELam p "_" inner)
    _ -> do
      v <- freshName
      return (ELam p v (EMatch p (EVar p v) [(pat, inner)]))

-- ---------------------------------------------------------------------------
-- Expressions

expr :: P Expr
expr = do
  e <- opExpr 1
  (p, t) <- peek
  if t == TSym ";" then advance >> ESeq p e <$> expr else return e

data Assoc = L | R | N

levels :: [[(String, Assoc)]]
levels =
  [ [("|>", L)]
  , [("||", R)]
  , [("&&", R)]
  , [("==", N), ("!=", N), ("<", N), ("<=", N), (">", N), (">=", N)]
  , [("@", R), ("^", R)]
  , [("::", R)]
  , [("+", L), ("-", L)]
  , [("*", L), ("/", L), ("%", L)]
  ]

opExpr :: Int -> P Expr
opExpr lvl
  | lvl > length levels = unary
  | otherwise = do
      lhs <- opExpr (lvl + 1)
      loop lhs
  where
    ops = levels !! (lvl - 1)
    loop lhs = do
      (p, t) <- peek
      case t of
        TSym s | Just assoc <- lookup s ops -> do
          _ <- advance
          case assoc of
            L -> do rhs <- opExpr (lvl + 1); loop (binop p s lhs rhs)
            R -> binop p s lhs <$> opExpr lvl
            N -> binop p s lhs <$> opExpr (lvl + 1)
        _ -> return lhs

binop :: Pos -> String -> Expr -> Expr -> Expr
binop _ op l r = let p = exprPos l in case op of
  "|>" -> EApp p r l
  "&&" -> EIf p l r (ELit p (LBool False))
  "||" -> EIf p l (ELit p (LBool True)) r
  "::" -> EApp p (EApp p (ECon p "Cons") l) r
  "@" -> EApp p (EApp p (EVar p "append") l) r
  _ -> EApp p (EApp p (EVar p op) l) r

unary :: P Expr
unary = do
  (p, t) <- peek
  case t of
    TSym "-" -> do _ <- advance; EApp p (EVar p "negate") <$> unary
    TKw "let" -> advance >> letExpr p
    TKw "if" -> do
      _ <- advance
      c <- expr
      _ <- expect (TKw "then")
      a <- expr
      _ <- expect (TKw "else")
      EIf p c a <$> expr
    TKw "fun" -> do
      _ <- advance
      params <- manyWhile startsAtomPat atomPat
      when (null params) $ failAt p "'fun' needs at least one parameter"
      _ <- expect (TSym "->")
      body <- expr
      lambdas p params body
    TKw "match" -> do
      _ <- advance
      scrut <- expr
      _ <- expect (TKw "with")
      _ <- optional' (TSym "|")
      first <- arm
      rest <- manyWhile (== TSym "|") (advance >> arm)
      return (EMatch p scrut (first : rest))
    _ -> application
  where
    arm = do
      pat <- pattern
      _ <- expect (TSym "->")
      body <- expr
      return (pat, body)

letExpr :: Pos -> P Expr
letExpr p = do
  isRec <- optional' (TKw "rec")
  if isRec
    then do
      bs <- recBindings
      _ <- expect (TKw "in")
      ELetRec p bs <$> expr
    else do
      (pat, rhs) <- binding
      _ <- expect (TKw "in")
      ELet p pat rhs <$> expr

startsAtom :: Token -> Bool
startsAtom t = case t of
  TInt _ -> True; TStr _ -> True; TLower _ -> True; TUpper _ -> True
  TKw "true" -> True; TKw "false" -> True
  TSym "(" -> True; TSym "[" -> True
  _ -> False

application :: P Expr
application = do
  f <- atom
  go f
  where
    go f = do
      (_, t) <- peek
      if startsAtom t then do a <- atom; go (EApp (exprPos f) f a) else return f

atom :: P Expr
atom = do
  (p, t) <- advance
  case t of
    TInt n -> return (ELit p (LInt n))
    TStr s -> return (ELit p (LStr s))
    TKw "true" -> return (ELit p (LBool True))
    TKw "false" -> return (ELit p (LBool False))
    TLower n -> return (EVar p n)
    TUpper c -> return (ECon p c)
    TSym "(" -> do
      closed <- optional' (TSym ")")
      if closed
        then return (ELit p LUnit)
        else do
          -- operator sections like (+) are handy for folds
          (_, t1) <- peek
          t2 <- peek2
          case (t1, t2) of
            (TSym op, TSym ")") | op `elem` sectionOps -> do
              _ <- advance; _ <- advance
              return (opFunction p op)
            _ -> do
              first <- expr
              more <- manyWhile (== TSym ",") (advance >> expr)
              _ <- expect (TSym ")")
              return (if null more then first else ETuple p (first : more))
    TSym "[" -> do
      closed <- optional' (TSym "]")
      if closed
        then return (ECon p "Nil")
        else do
          first <- expr
          more <- manyWhile (== TSym ",") (advance >> expr)
          _ <- expect (TSym "]")
          return (foldr (\x acc -> EApp p (EApp p (ECon p "Cons") x) acc) (ECon p "Nil") (first : more))
    _ -> failAt p ("expected an expression but found " ++ describe t)

sectionOps :: [String]
sectionOps = ["+", "-", "*", "/", "%", "==", "!=", "<", "<=", ">", ">=", "^", "@", "::", "&&", "||"]

opFunction :: Pos -> String -> Expr
opFunction p op = ELam p "$a" (ELam p "$b" (binop p op (EVar p "$a") (EVar p "$b")))

-- ---------------------------------------------------------------------------
-- Patterns

startsAtomPat :: Token -> Bool
startsAtomPat t = case t of
  TInt _ -> True; TStr _ -> True; TLower _ -> True; TUpper _ -> True
  TKw "true" -> True; TKw "false" -> True
  TSym "(" -> True; TSym "[" -> True; TSym "_" -> True; TSym "-" -> True
  _ -> False

pattern :: P Pat
pattern = do
  hd <- conPattern
  (p, t) <- peek
  if t == TSym "::"
    then do _ <- advance; tl <- pattern; return (PCon p "Cons" [hd, tl])
    else return hd

conPattern :: P Pat
conPattern = do
  (p, t) <- peek
  case t of
    TUpper c -> do
      _ <- advance
      args <- manyWhile startsAtomPat atomPat
      return (PCon p c args)
    _ -> atomPat

atomPat :: P Pat
atomPat = do
  (p, t) <- advance
  case t of
    TSym "_" -> return PWild
    TLower n -> return (PVar n)
    TUpper c -> return (PCon p c [])
    TInt n -> return (PLit (LInt n))
    TSym "-" -> do
      (p', t') <- advance
      case t' of
        TInt n -> return (PLit (LInt (negate n)))
        _ -> failAt p' "expected an integer after '-' in a pattern"
    TStr s -> return (PLit (LStr s))
    TKw "true" -> return (PLit (LBool True))
    TKw "false" -> return (PLit (LBool False))
    TSym "(" -> do
      closed <- optional' (TSym ")")
      if closed
        then return (PLit LUnit)
        else do
          first <- pattern
          more <- manyWhile (== TSym ",") (advance >> pattern)
          _ <- expect (TSym ")")
          return (if null more then first else PTuple (first : more))
    TSym "[" -> do
      closed <- optional' (TSym "]")
      if closed
        then return (PCon p "Nil" [])
        else do
          first <- pattern
          more <- manyWhile (== TSym ",") (advance >> pattern)
          _ <- expect (TSym "]")
          return (foldr (\x acc -> PCon p "Cons" [x, acc]) (PCon p "Nil" []) (first : more))
    _ -> failAt p ("expected a pattern but found " ++ describe t)
