{-# LANGUAGE TemplateHaskell #-}

module Main (main) where

import Control.Monad (foldM, forM_, unless, when)
import Data.Char (isSpace)
import Data.List (isPrefixOf)
import qualified Data.Map.Strict as M
import Eval
import Exhaust
import Fuzz (fuzzMain)
import Infer
import Language.Haskell.TH.Syntax (addDependentFile, lift, runIO)
import Parser
import Syntax
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO

preludeSource :: String
preludeSource = $(addDependentFile "src/Prelude.moss" >> runIO (readFile "src/Prelude.moss") >>= lift)

data Session = Session { sTEnv :: TEnv, sEnv :: Env }

-- | Point at the offending source location, compiler-style.
report :: String -> String -> Pos -> String -> String
report file src p@(Pos l c) msg
  | l <= 0 = file ++ ": " ++ msg
  | otherwise =
      let srcLine = case drop (l - 1) (lines src) of (x : _) -> x; [] -> ""
          gutter = show l ++ " | "
       in file ++ ":" ++ show p ++ ": " ++ msg ++ "\n"
            ++ gutter ++ srcLine ++ "\n"
            ++ replicate (length gutter + c - 1) ' ' ++ "^"

-- | Type-check every declaration (aborting on the first error), collecting
--   exhaustiveness warnings and the inferred schemes.
checkProgram :: TEnv -> [Decl] -> Either TypeError (TEnv, [(Name, Scheme)], [Warning])
checkProgram env0 = foldM step (env0, [], [])
  where
    step (env, shown, ws) d = do
      (env', s) <- inferDecl env d
      return (env', shown ++ s, ws ++ checkDecl (siblingsOf env') d)

loadPrelude :: IO Session
loadPrelude = do
  decls <- either (\(p, m) -> die' ("prelude parse error at " ++ show p ++ ": " ++ m)) return (parseProgram preludeSource)
  (tenv, _, ws) <- either (\(TypeError p m) -> die' (report "<prelude>" preludeSource p m)) return (checkProgram initialTEnv decls)
  unless (null ws) $ die' ("prelude warnings:\n" ++ unlines (map showWarning ws))
  (r, _) <- runEval maxBound (foldM (\e d -> fst <$> evalDecl e d) initialEnv decls)
  env <- either (die' . showRunErr) return r
  return (Session tenv env)

die' :: String -> IO a
die' m = hPutStrLn stderr m >> exitFailure

main :: IO ()
main = do
  hSetEncoding stdout utf8
  args <- getArgs
  sess <- loadPrelude
  case args of
    ["--fuzz", n] -> fuzzMain (sTEnv sess) (sEnv sess) (read n) 2026
    ["--fuzz", n, seed] -> fuzzMain (sTEnv sess) (sEnv sess) (read n) (read seed)
    ["--types", f] -> runFile sess f True
    [f] | not ("-" `isPrefixOf` f) -> runFile sess f False
    [] -> repl sess
    _ -> die' "usage: moss [FILE | --types FILE | --fuzz N [SEED]]   (no arguments starts the REPL)"

runFile :: Session -> FilePath -> Bool -> IO ()
runFile sess file typesOnly = do
  src <- readFile file
  decls <- either (\(p, m) -> die' (report file src p ("syntax error: " ++ m))) return (parseProgram src)
  (_, shown, ws) <- either (\(TypeError p m) -> die' (report file src p ("type error: " ++ m))) return (checkProgram (sTEnv sess) decls)
  forM_ ws $ \w -> hPutStrLn stderr (file ++ ":" ++ showWarning w)
  if typesOnly
    then forM_ shown $ \(n, s) -> putStrLn (n ++ " : " ++ prettyScheme s)
    else do
      (r, _) <- runEval maxBound (foldM (\e d -> fst <$> evalDecl e d) (sEnv sess) decls)
      case r of
        Left err -> die' (case err of MatchFail p -> report file src p "runtime error: match failure"; _ -> "runtime " ++ showRunErr err)
        Right _ -> return ()

-- ---------------------------------------------------------------------------
-- REPL

repl :: Session -> IO ()
repl sess0 = do
  tty <- hIsTerminalDevice stdin
  when tty $ putStrLn "Moss REPL. Declarations (let/data) or expressions; :t EXPR shows a type; :q quits."
  let loop sess = do
        putStr "moss> " >> hFlush stdout
        eof <- isEOF
        if eof
          then unless tty (putStrLn "")
          else do
            line <- getLine
            unless tty (putStrLn line)
            case trim line of
              "" -> loop sess
              ":q" -> return ()
              l | ":t " `isPrefixOf` l -> typeOf sess (drop 3 l) >> loop sess
              l -> step sess l >>= loop
  loop sess0
  where
    trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

typeOf :: Session -> String -> IO ()
typeOf sess src = case parseReplLine src of
  Left (p, m) -> putStrLn (report "<repl>" src p ("syntax error: " ++ m))
  Right [DExpr _ e] -> case inferTopExpr (sTEnv sess) e of
    Left (TypeError p m) -> putStrLn (report "<repl>" src p ("type error: " ++ m))
    Right s -> putStrLn (prettyScheme s)
  Right _ -> putStrLn ":t expects an expression"

step :: Session -> String -> IO Session
step sess src = case parseReplLine src of
  Left (p, m) -> putStrLn (report "<repl>" src p ("syntax error: " ++ m)) >> return sess
  Right decls -> case checkProgram (sTEnv sess) decls of
    Left (TypeError p m) -> putStrLn (report "<repl>" src p ("type error: " ++ m)) >> return sess
    Right (tenv', shown, ws) -> do
      mapM_ (putStrLn . showWarning) ws
      (r, _) <- runEval maxBound (mapM' decls)
      case r of
        Left err -> putStrLn (showRunErr err) >> return sess
        Right (env', vals) -> do
          let vmap = M.fromList vals
          forM_ shown $ \(n, s) -> case M.lookup n vmap of
            Just v -> putStrLn (n ++ " : " ++ prettyScheme s ++ " = " ++ showValue v)
            Nothing -> putStrLn (n ++ " : " ++ prettyScheme s)
          return (Session tenv' env')
  where
    mapM' = foldM (\(e, acc) d -> do (e', vs) <- evalDecl e d; return (e', acc ++ vs)) (sEnv sess, [])
