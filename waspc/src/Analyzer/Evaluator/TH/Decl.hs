{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

module Analyzer.Evaluator.TH.Decl
  ( makeDeclType,
  )
where

import AST.Core.Ref (Ref)
import Analyzer.Evaluator.Decl.Operations (makeDecl)
import Analyzer.Evaluator.Evaluation
import Analyzer.Evaluator.TH.Common
import qualified Analyzer.Evaluator.Types as E
import qualified Analyzer.Type as T
import Analyzer.TypeDefinitions (DeclType (..), EnumType (..), IsDeclType (..), IsEnumType (..))
import qualified Data.HashMap.Strict as H
import Language.Haskell.TH

-- | @makeDeclType ''Type@ writes an @IsDeclType@ instance for @Type@. A type
-- error is raised if @Type@ does not fit the criteria described below.
--
-- Requirements on @Type@ for this to work:
--  - The type must be an ADT with one constructor.
--  - The type must have just one field OR use record syntax (in which case it can have multiple fields).
--
-- Properties that hold for @Type@ and its generated @IsDeclType@ instance:
--   - For the rest of the bullet points below, let's say that
--     @let bodyType = dtBodyType (declType \@Type)@.
--   - If @Type@ uses record syntax, then
--     - @bodyType@ is a @Dict@
--     - If and only if there is a key @x@ in @bodyType@,
--       then @Type@ has a record @x@ with the same type.
--     - If a key @x@ is optional, then the record @x@ in @Type@ is a @Maybe@.
--   - If @Type@ is a simple ADT (not record) with one field, then @bodyType@ maps to the type of that field.
--   - @dtName (declType \@Type) == "type"@ -> the name of declaration type is the same as the name of @Type@
--     but with the first letter changed to lowercase.
--
-- One way to summarize the crux of properties above is to say: If given @Type@ is a simple ADT with one field,
-- it is translated into a declaration which has body corresponding to that field. If instead @Type@
-- is a record, it is translated into a declaration whose body is a dictionary with same fields as the record.
--
-- __Examples__
--
-- __Calling @makeDeclType@ on record__
-- @
-- >>> data User = User { name :: String, email :: Maybe String }
-- >>> makeDeclType ''User   -- "IsDeclType User" instance is generated.
-- >>> dtName $ declType @User
-- "user"
-- >>> dtBodyType $ declType @User
-- DictType [DictEntry "name" StringType, DictOptionalEntry "email" StringLiteral]
-- @
--
-- Such declaration type would be used in Wasp lang source somewhat like:
-- @
-- user MyUser { name: "testUser", email: "testuser@wasp-lang.dev" }
-- @
--
--
-- __Calling @makeDeclType@ on a simple ADT with one field__
-- @
-- >>> data Admins = Admins [User]
-- >>> makeDeclType ''Admins  -- "IsDeclType Admins" instance is generated.
-- >>> dtBodyType $ declType @Admins
-- ListType (DeclType "User")
-- @
--
-- Such declaration type would be used in Wasp lang source somewhat like:
-- @
-- admins MainAdmins [MyUser, SomeOtherUser]
-- @
makeDeclType :: Name -> Q [Dec]
makeDeclType typeName = do
  (TyConI typeDeclaration) <- reify typeName
  dataConstructor <- case typeDeclaration of
    (DataD _ _ [] _ [dataConstructor] _) -> pure dataConstructor
    DataD {} -> fail "makeDeclType expects a type declared with `data` to have exactly one constructor and no type variables."
    (NewtypeD _ _ [] _ dataConstructor _) -> pure dataConstructor
    NewtypeD {} -> fail "makeDeclType expects a type declared with `newtype` to have no type variables."
    _ -> fail "makeDeclType expects the given name to be for a type declared with `data` or `newtype`"
  let instanceDeclaration = instanceD instanceContext instanceType =<< instanceDefinition
      instanceContext = pure []
      instanceType = [t|IsDeclType $(conT typeName)|]
      instanceDefinition = makeIsDeclTypeInstanceDefinition typeName dataConstructor
  sequence [instanceDeclaration]

-- | Top-level "IsDeclType" instance generator.
makeIsDeclTypeInstanceDefinition :: Name -> Con -> Q [DecQ]
-- The constructor is in the form @data Type = Type x@
makeIsDeclTypeInstanceDefinition typeName _dataConstructor@(NormalC conName [(_, conType)]) =
  genIsDeclTypeInstanceDefinitionFromNormalDataConstructor typeName conName conType
-- The constructor is in the form @data Type = Type x1 x2 ... xn@, which is not valid for a decl
makeIsDeclTypeInstanceDefinition typeName _dataConstructor@(NormalC _ values) =
  fail $
    "makeDeclType expects given type " ++ show typeName
      ++ " to be a record or to have one data constructor with exactly 1 value, "
      ++ "but instead it was given a data constructor with "
      ++ show (length values)
      ++ "values."
-- The constructor is in the form @data Type = Type { k1 :: f1, ..., kn :: fn }
makeIsDeclTypeInstanceDefinition typeName _dataConstructor@(RecC conName records) =
  genIsDeclTypeInstanceDefinitionFromRecordDataConstructor typeName conName $
    map (\(fieldName, _, fieldType) -> (fieldName, fieldType)) records
-- The constructor is in an unsupported form
makeIsDeclTypeInstanceDefinition _ _ = fail "makeDeclType expects given type to have a normal or record constructor"

-- | Create an "IsDeclType" instance for types that have a single data constructor which has a single value, e.g. @data Type = Type x@.
genIsDeclTypeInstanceDefinitionFromNormalDataConstructor :: Name -> Name -> Type -> Q [DecQ]
genIsDeclTypeInstanceDefinitionFromNormalDataConstructor typeName dataConstructorName dataConstructorType = do
  let evaluateE = [|runEvaluation $ $(conE dataConstructorName) <$> $(genEvaluationExprForHaskellType dataConstructorType)|]
  let bodyTypeE = genWaspTypeFromHaskellType dataConstructorType
  pure $ genIsDeclTypeInstanceDefinition typeName dataConstructorName bodyTypeE evaluateE

-- | For decls with record constructors, i.e. @data Fields = Fields { a :: String, b :: String }
genIsDeclTypeInstanceDefinitionFromRecordDataConstructor :: Name -> Name -> [(Name, Type)] -> Q [DecQ]
genIsDeclTypeInstanceDefinitionFromRecordDataConstructor typeName dataConstructorName fields = do
  (dictEntryTypesE, dictEvaluationE) <- genDictEntryTypesAndEvaluationForRecord dataConstructorName fields
  let evaluateE = [|runEvaluation $ dict $dictEvaluationE|]
  let bodyTypeE = [|T.DictType $ H.fromList $dictEntryTypesE|]
  pure $ genIsDeclTypeInstanceDefinition typeName dataConstructorName bodyTypeE evaluateE

-- | Generates 'declType' function for a definition of IsDeclType instance.
-- A helper function for 'genPrimDecl' and 'genRecDecl'.
genIsDeclTypeInstanceDefinition :: Name -> Name -> ExpQ -> ExpQ -> [DecQ]
genIsDeclTypeInstanceDefinition typeName dataConstructorName bodyTypeE evaluateE =
  [ genFunc
      'declType
      [|
        DeclType
          { dtName = $(nameToLowerFirstStringLiteralExpr dataConstructorName),
            dtBodyType = $bodyTypeE,
            dtEvaluate = \typeDefs bindings declName declBodyExpr ->
              makeDecl @ $(conT typeName) declName <$> declEvaluate typeDefs bindings declBodyExpr
          }
        |],
    genFunc 'declEvaluate evaluateE
  ]

--------------- Dict ------------------

-- | Write the @DictEntryType@s and @DictEvaluation@ for the Haskell record with given data constructor name and fields.
genDictEntryTypesAndEvaluationForRecord :: Name -> [(Name, Type)] -> Q (ExpQ, ExpQ)
genDictEntryTypesAndEvaluationForRecord dataConstructorName fields =
  go $ reverse fields -- Reversing enables us to apply evaluations in right order.
  where
    go [] = pure (listE [], varE 'pure `appE` conE dataConstructorName)
    go ((fieldName, fieldType) : restOfFields) = do
      (restDictType, restEvaluation) <- go restOfFields
      let thisDictTypeE =
            [|
              ($(nameToStringLiteralExpr fieldName), $(genDictEntryTypeFromHaskellType fieldType)) :
              $restDictType
              |]
      let thisEvaluationE = [|$restEvaluation <*> $(genDictEntryEvaluationForRecordField fieldName fieldType)|]
      pure (thisDictTypeE, thisEvaluationE)

-- | Write a @DictEntryType@ that corresponds to a given a Haskell type.
genDictEntryTypeFromHaskellType :: Type -> ExpQ
genDictEntryTypeFromHaskellType typ =
  waspKindOfType typ >>= \case
    KOptional elemType -> [|T.DictOptional $(genWaspTypeFromHaskellType elemType)|]
    _ -> [|T.DictRequired $(genWaspTypeFromHaskellType typ)|]

-- | "genDictEvaluationE fieldName typ" writes a "DictEvaluation" for a haskell record field
-- named "fieldName" with a value "typ".
genDictEntryEvaluationForRecordField :: Name -> Type -> ExpQ
genDictEntryEvaluationForRecordField fieldName fieldType =
  waspKindOfType fieldType >>= \case
    KOptional elemType -> [|maybeField $(nameToStringLiteralExpr fieldName) $(genEvaluationExprForHaskellType elemType)|]
    _ -> [|field $(nameToStringLiteralExpr fieldName) $(genEvaluationExprForHaskellType fieldType)|]

----------------------------------------

--------------- Types ------------------

-- | Haskell type -> Wasp type.
genWaspTypeFromHaskellType :: Type -> ExpQ
genWaspTypeFromHaskellType typ =
  waspKindOfType typ >>= \case
    KString -> [|T.StringType|]
    KInteger -> [|T.NumberType|]
    KDouble -> [|T.NumberType|]
    KBool -> [|T.BoolType|]
    KList elemType -> [|T.ListType $(genWaspTypeFromHaskellType elemType)|]
    KImport -> [|T.ExtImportType|]
    KJSON -> [|T.QuoterType "json"|]
    KPSL -> [|T.QuoterType "psl"|]
    KDeclRef t -> [|T.DeclType $ dtName $ declType @ $(pure t)|]
    KEnum -> [|T.EnumType $ etName $ enumType @ $(pure typ)|]
    KOptional _ -> fail "Maybe is only allowed in record fields"

-- | Generates an expression that is @Evaluation@ that evaluates to a given Haskell type.
genEvaluationExprForHaskellType :: Type -> ExpQ
genEvaluationExprForHaskellType typ =
  waspKindOfType typ >>= \case
    KString -> [|string|]
    KInteger -> [|integer|]
    KDouble -> [|double|]
    KBool -> [|bool|]
    KList elemType -> [|list $(genEvaluationExprForHaskellType elemType)|]
    KImport -> [|extImport|]
    KJSON -> [|json|]
    KPSL -> [|psl|]
    KDeclRef t -> [|declRef @ $(pure t)|]
    KEnum -> [|enum @ $(pure typ)|]
    KOptional _ -> fail "Maybe is only allowed in record fields"

-- | Find the "WaspKind" of a Haskell type.
waspKindOfType :: Type -> Q WaspKind
waspKindOfType typ = do
  maybeDeclRefKind <- tryCastingToDeclRefKind typ
  maybeEnumKind <- tryCastingToEnumKind typ
  case maybeDeclRefKind of
    Just declRefKind -> pure declRefKind
    Nothing -> case maybeEnumKind of
      Just enumKind -> pure enumKind
      Nothing -> case typ of
        ConT name
          | name == ''String -> pure KString
          | name == ''Integer -> pure KInteger
          | name == ''Double -> pure KDouble
          | name == ''Bool -> pure KBool
          | name == ''E.ExtImport -> pure KImport
          | name == ''E.JSON -> pure KJSON
          | name == ''E.PSL -> pure KPSL
        ListT `AppT` elemType -> pure (KList elemType)
        ConT name `AppT` elemType | name == ''Maybe -> pure (KOptional elemType)
        _ -> fail $ "No translation to wasp type for type " ++ show typ
  where
    tryCastingToDeclRefKind :: Type -> Q (Maybe WaspKind)
    tryCastingToDeclRefKind (ConT name `AppT` subType) | name == ''Ref = do
      isDeclTypeRef <- isInstance ''IsDeclType [subType]
      return $ if isDeclTypeRef then Just (KDeclRef subType) else Nothing
    tryCastingToDeclRefKind _ = return Nothing

    tryCastingToEnumKind :: Type -> Q (Maybe WaspKind)
    tryCastingToEnumKind t = do
      isEnumType <- isInstance ''IsEnumType [t]
      return $ if isEnumType then Just KEnum else Nothing

-- | An intermediate mapping between Haskell types and Wasp types, we use it internally
-- in this module when generating @Types@, @Evaluation@, @DictEntryTypes@, and @DictEvaluation@
-- so that we have easier time when figuring out what we are dealing with.
data WaspKind
  = KString
  | KInteger
  | KDouble
  | KBool
  | KList Type
  | KImport
  | KJSON
  | KPSL
  | -- | Reference to a declaration type @Type@.
    KDeclRef Type
  | KEnum
  | -- | Valid only in a record field, represents @DictOptional@/@Maybe@
    KOptional Type

---------------------------------------
