-- | Hand-written lexer producing positioned tokens.
module Lexer (Token (..), lexMoss) where

import Data.Char (isAlphaNum, isDigit, isLower, isSpace, isUpper)
import Data.List (isPrefixOf)
import Syntax

data Token
  = TInt Integer
  | TStr String
  | TLower Name
  | TUpper Name
  | TKw String
  | TSym String
  | TEOF
  deriving (Eq, Show)

keywords :: [String]
keywords = ["let", "rec", "and", "in", "fun", "match", "with", "if", "then", "else", "data", "true", "false"]

-- Longest symbols first so that "::" wins over ":" etc.
symbols :: [String]
symbols =
  [ "->", "::", "==", "!=", "<=", ">=", "&&", "||", "|>"
  , "|", "=", "(", ")", "[", "]", ",", ";", "@", "^", "+", "-", "*", "/", "%", "<", ">", "_"
  ]

lexMoss :: String -> Either (Pos, String) [(Pos, Token)]
lexMoss = go 1 1
  where
    go :: Int -> Int -> String -> Either (Pos, String) [(Pos, Token)]
    go l c [] = Right [(Pos l c, TEOF)]
    go l c s@(ch : rest)
      | ch == '\n' = go (l + 1) 1 rest
      | isSpace ch = go l (c + 1) rest
      | "--" `isPrefixOf` s = go l c (dropWhile (/= '\n') s)
      | isDigit ch =
          let (ds, rest') = span isDigit s
           in ((Pos l c, TInt (read ds)) :) <$> go l (c + length ds) rest'
      | ch == '"' = lexString l c (c + 1) "" rest
      | isLower ch || (ch == '_' && identTail rest) =
          let (w, rest') = span isIdent s
              tok = if w `elem` keywords then TKw w else TLower w
           in ((Pos l c, tok) :) <$> go l (c + length w) rest'
      | isUpper ch =
          let (w, rest') = span isIdent s
           in ((Pos l c, TUpper w) :) <$> go l (c + length w) rest'
      | otherwise = case filter (`isPrefixOf` s) symbols of
          (sym : _) -> ((Pos l c, TSym sym) :) <$> go l (c + length sym) (drop (length sym) s)
          [] -> Left (Pos l c, "unexpected character " ++ show ch)

    identTail (x : _) = isAlphaNum x || x == '_'
    identTail [] = False
    isIdent x = isAlphaNum x || x == '_' || x == '\''

    lexString l c0 c acc s = case s of
      [] -> Left (Pos l c0, "unterminated string literal")
      ('"' : rest) -> ((Pos l c0, TStr (reverse acc)) :) <$> go l (c + 1) rest
      ('\\' : e : rest) -> case lookup e escapes of
        Just ch -> lexString l c0 (c + 2) (ch : acc) rest
        Nothing -> Left (Pos l c, "unknown escape \\" ++ [e])
      ('\n' : _) -> Left (Pos l c0, "newline in string literal")
      (ch : rest) -> lexString l c0 (c + 1) (ch : acc) rest

    escapes = [('n', '\n'), ('t', '\t'), ('\\', '\\'), ('"', '"')]
