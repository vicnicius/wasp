module Parser
  ( parseWasp,
  )
where

import Lexer
import qualified Parser.Action
import Parser.App (app)
import Parser.Auth (auth)
import Parser.Common (runWaspParser)
import Parser.Db (db)
import Parser.Entity (entity)
import Parser.JsImport (jsImport)
import qualified Parser.NpmDependencies
import Parser.Page (page)
import qualified Parser.Query
import Parser.Route (route)
import qualified Parser.Server
import Text.Parsec (ParseError, eof, many, many1, (<|>))
import Text.Parsec.String (Parser)
import qualified Wasp

waspElement :: Parser Wasp.WaspElement
waspElement =
  waspElementApp
    <|> waspElementAuth
    <|> waspElementPage
    <|> waspElementDb
    <|> waspElementRoute
    <|> waspElementEntity
    <|> waspElementQuery
    <|> waspElementAction
    <|> waspElementNpmDependencies
    <|> waspElementServer

waspElementApp :: Parser Wasp.WaspElement
waspElementApp = Wasp.WaspElementApp <$> app

waspElementAuth :: Parser Wasp.WaspElement
waspElementAuth = Wasp.WaspElementAuth <$> auth

waspElementDb :: Parser Wasp.WaspElement
waspElementDb = Wasp.WaspElementDb <$> db

waspElementPage :: Parser Wasp.WaspElement
waspElementPage = Wasp.WaspElementPage <$> page

waspElementRoute :: Parser Wasp.WaspElement
waspElementRoute = Wasp.WaspElementRoute <$> route

waspElementEntity :: Parser Wasp.WaspElement
waspElementEntity = Wasp.WaspElementEntity <$> entity

waspElementQuery :: Parser Wasp.WaspElement
waspElementQuery = Wasp.WaspElementQuery <$> Parser.Query.query

waspElementAction :: Parser Wasp.WaspElement
waspElementAction = Wasp.WaspElementAction <$> Parser.Action.action

waspElementServer :: Parser Wasp.WaspElement
waspElementServer = Wasp.WaspElementServer <$> Parser.Server.server

waspElementNpmDependencies :: Parser Wasp.WaspElement
waspElementNpmDependencies = Wasp.WaspElementNpmDependencies <$> Parser.NpmDependencies.npmDependencies

-- | Top level parser, produces Wasp.
waspParser :: Parser Wasp.Wasp
waspParser = do
  -- NOTE(matija): this is the only place we need to use whiteSpace, to skip empty lines
  -- and comments in the beginning of file. All other used parsers are lexeme parsers
  -- so they do it themselves.
  whiteSpace

  jsImports <- many jsImport

  waspElems <- many1 waspElement

  eof

  -- TODO(matija): after we parsed everything, we should do semantic analysis
  -- e.g. check there is only 1 title - if not, throw a meaningful error.
  -- Also, check there is at least one Page defined.

  return $ Wasp.fromWaspElems waspElems `Wasp.setJsImports` jsImports

-- | Top level parser executor.
parseWasp :: String -> Either ParseError Wasp.Wasp
parseWasp = runWaspParser waspParser
