-- | Stuff gutted from Translate.Select.
module Hasura.Backends.Postgres.Translate.Select.Internal.Helpers
  ( mkFirstElementExp,
    mkLastElementExp,
    cursorIdentifier,
    startCursorIdentifier,
    endCursorIdentifier,
    hasNextPageIdentifier,
    hasPreviousPageIdentifier,
    pageInfoSelectAlias,
    pageInfoSelectAliasIdentifier,
    cursorsSelectAlias,
    cursorsSelectAliasIdentifier,
    encodeBase64,
    fromTableRowArgs,
    selectFromToFromItem,
    functionToIdentifier,
    withJsonBuildObj,
    withForceAggregation,
  )
where

import Hasura.Backends.Postgres.SQL.DML qualified as S
import Hasura.Backends.Postgres.SQL.Types
  ( Identifier (..),
    QualifiedFunction,
    TableIdentifier (..),
    qualifiedObjectToText,
    tableIdentifierToIdentifier,
  )
import Hasura.Backends.Postgres.Translate.Select.Internal.Aliases
import Hasura.Backends.Postgres.Types.Function
import Hasura.Prelude
import Hasura.RQL.IR
import Hasura.RQL.Types.Common (FieldName)
import Hasura.RQL.Types.Function
import Hasura.SQL.Backend

-- | First element extractor expression from given record set
-- For example:- To get first "id" column from given row set,
-- the function generates the SQL expression AS `(array_agg("id"))[1]`
mkFirstElementExp :: S.SQLExp -> S.SQLExp
mkFirstElementExp expIdentifier =
  -- For Example
  S.SEArrayIndex (S.SEFnApp "array_agg" [expIdentifier] Nothing) (S.intToSQLExp 1)

-- | Last element extractor expression from given record set.
-- For example:- To get first "id" column from given row set,
-- the function generates the SQL expression AS `(array_agg("id"))[array_length(array_agg("id"), 1)]`
mkLastElementExp :: S.SQLExp -> S.SQLExp
mkLastElementExp expIdentifier =
  let arrayExp = S.SEFnApp "array_agg" [expIdentifier] Nothing
   in S.SEArrayIndex arrayExp $
        S.SEFnApp "array_length" [arrayExp, S.intToSQLExp 1] Nothing

cursorIdentifier :: Identifier
cursorIdentifier = Identifier "__cursor"

startCursorIdentifier :: Identifier
startCursorIdentifier = Identifier "__start_cursor"

endCursorIdentifier :: Identifier
endCursorIdentifier = Identifier "__end_cursor"

hasPreviousPageIdentifier :: Identifier
hasPreviousPageIdentifier = Identifier "__has_previous_page"

hasNextPageIdentifier :: Identifier
hasNextPageIdentifier = Identifier "__has_next_page"

pageInfoSelectAlias :: S.TableAlias
pageInfoSelectAlias = S.mkTableAlias "__page_info"

pageInfoSelectAliasIdentifier :: TableIdentifier
pageInfoSelectAliasIdentifier = S.tableAliasToIdentifier pageInfoSelectAlias

cursorsSelectAlias :: S.TableAlias
cursorsSelectAlias = S.mkTableAlias "__cursors_select"

cursorsSelectAliasIdentifier :: TableIdentifier
cursorsSelectAliasIdentifier = S.tableAliasToIdentifier cursorsSelectAlias

encodeBase64 :: S.SQLExp -> S.SQLExp
encodeBase64 =
  removeNewline . bytesToBase64Text . convertToBytes
  where
    convertToBytes e =
      S.SEFnApp "convert_to" [e, S.SELit "UTF8"] Nothing
    bytesToBase64Text e =
      S.SEFnApp "encode" [e, S.SELit "base64"] Nothing
    removeNewline e =
      S.SEFnApp "regexp_replace" [e, S.SELit "\\n", S.SELit "", S.SELit "g"] Nothing

fromTableRowArgs ::
  TableIdentifier -> FunctionArgsExpG (ArgumentExp S.SQLExp) -> S.FunctionArgs
fromTableRowArgs prefix = toFunctionArgs . fmap toSQLExp
  where
    toFunctionArgs (FunctionArgsExp positional named) =
      S.FunctionArgs positional named
    toSQLExp =
      onArgumentExp
        (S.SERowIdentifier (tableIdentifierToIdentifier baseTableIdentifier))
        (S.mkQIdenExp baseTableIdentifier . Identifier)
    baseTableIdentifier = mkBaseTableIdentifier prefix

selectFromToFromItem :: TableIdentifier -> SelectFrom ('Postgres pgKind) -> S.FromItem
selectFromToFromItem prefix = \case
  FromTable tn -> S.FISimple tn Nothing
  FromIdentifier i -> S.FIIdentifier $ TableIdentifier $ unFIIdentifier i
  FromFunction qf args defListM ->
    S.FIFunc $
      S.FunctionExp qf (fromTableRowArgs prefix args) $
        Just $
          S.mkFunctionAlias
            qf
            (fmap (fmap (first S.toColumnAlias)) defListM)

-- | Converts a function name to an 'Identifier'.
--
-- If the schema name is public, it will just use its name, otherwise it will
-- prefix it by the schema name.
functionToIdentifier :: QualifiedFunction -> Identifier
functionToIdentifier = Identifier . qualifiedObjectToText

-- uses json_build_object to build a json object
withJsonBuildObj ::
  FieldName -> [S.SQLExp] -> (S.ColumnAlias, S.SQLExp)
withJsonBuildObj parAls exps =
  (S.toColumnAlias parAls, jsonRow)
  where
    jsonRow = S.applyJsonBuildObj exps

-- | Forces aggregation
withForceAggregation :: S.TypeAnn -> S.SQLExp -> S.SQLExp
withForceAggregation tyAnn e =
  -- bool_or to force aggregation
  S.SEFnApp "coalesce" [e, S.SETyAnn (S.SEUnsafe "bool_or('true')") tyAnn] Nothing
