module Hasura.RQL.DML.Update
  ( runUpdate,
  )
where

import Control.Monad.Trans.Control (MonadBaseControl)
import Data.Aeson.Types
import Data.HashMap.Strict qualified as M
import Data.HashMap.Strict qualified as Map
import Data.Sequence qualified as DS
import Data.Text.Extended
import Database.PG.Query qualified as PG
import Hasura.Backends.Postgres.Connection
import Hasura.Backends.Postgres.Execute.Mutation
import Hasura.Backends.Postgres.SQL.DML qualified as S
import Hasura.Backends.Postgres.SQL.Types
import Hasura.Backends.Postgres.Translate.Returning
import Hasura.Backends.Postgres.Types.Table
import Hasura.Backends.Postgres.Types.Update
import Hasura.Base.Error
import Hasura.EncJSON
import Hasura.Prelude
import Hasura.QueryTags
import Hasura.RQL.DML.Internal
import Hasura.RQL.DML.Types
import Hasura.RQL.IR.BoolExp
import Hasura.RQL.IR.Update
import Hasura.RQL.Types.Column
import Hasura.RQL.Types.Common
import Hasura.RQL.Types.Metadata
import Hasura.RQL.Types.Permission
import Hasura.RQL.Types.SchemaCache
import Hasura.RQL.Types.Table
import Hasura.SQL.Backend
import Hasura.SQL.Types
import Hasura.Server.Types
import Hasura.Session
import Hasura.Tracing qualified as Tracing

convInc ::
  (QErrM m) =>
  ValueParser ('Postgres 'Vanilla) m S.SQLExp ->
  PGCol ->
  ColumnType ('Postgres 'Vanilla) ->
  Value ->
  m (PGCol, S.SQLExp)
convInc f col colType val = do
  prepExp <- f (CollectableTypeScalar colType) val
  return (col, S.SEOpApp S.incOp [S.mkSIdenExp col, prepExp])

convMul ::
  (QErrM m) =>
  ValueParser ('Postgres 'Vanilla) m S.SQLExp ->
  PGCol ->
  ColumnType ('Postgres 'Vanilla) ->
  Value ->
  m (PGCol, S.SQLExp)
convMul f col colType val = do
  prepExp <- f (CollectableTypeScalar colType) val
  return (col, S.SEOpApp S.mulOp [S.mkSIdenExp col, prepExp])

convSet ::
  (QErrM m) =>
  ValueParser ('Postgres 'Vanilla) m S.SQLExp ->
  PGCol ->
  ColumnType ('Postgres 'Vanilla) ->
  Value ->
  m (PGCol, S.SQLExp)
convSet f col colType val = do
  prepExp <- f (CollectableTypeScalar colType) val
  return (col, prepExp)

convDefault :: (Monad m) => PGCol -> ColumnType ('Postgres 'Vanilla) -> () -> m (PGCol, S.SQLExp)
convDefault col _ _ = return (col, S.SEUnsafe "DEFAULT")

convOp ::
  (UserInfoM m, QErrM m) =>
  FieldInfoMap (FieldInfo ('Postgres 'Vanilla)) ->
  [PGCol] ->
  UpdPermInfo ('Postgres 'Vanilla) ->
  [(PGCol, a)] ->
  (PGCol -> ColumnType ('Postgres 'Vanilla) -> a -> m (PGCol, S.SQLExp)) ->
  m [(PGCol, S.SQLExp)]
convOp fieldInfoMap preSetCols updPerm objs conv =
  forM objs $ \(pgCol, a) -> do
    -- if column has predefined value then throw error
    when (pgCol `elem` preSetCols) $ throwNotUpdErr pgCol
    checkPermOnCol PTUpdate allowedCols pgCol
    colType <- askColumnType fieldInfoMap pgCol relWhenPgErr
    res <- conv pgCol colType a
    -- build a set expression's entry
    withPathK (getPGColTxt pgCol) $ return res
  where
    allowedCols = upiCols updPerm
    relWhenPgErr = "relationships can't be updated"
    throwNotUpdErr c = do
      roleName <- _uiRole <$> askUserInfo
      throw400 NotSupported $
        "column "
          <> c <<> " is not updatable"
          <> " for role "
          <> roleName <<> "; its value is predefined in permission"

validateUpdateQueryWith ::
  (UserInfoM m, QErrM m, TableInfoRM ('Postgres 'Vanilla) m) =>
  SessionVariableBuilder m ->
  ValueParser ('Postgres 'Vanilla) m S.SQLExp ->
  UpdateQuery ->
  m (AnnotatedUpdate ('Postgres 'Vanilla))
validateUpdateQueryWith sessVarBldr prepValBldr uq = do
  let tableName = uqTable uq
  tableInfo <- withPathK "table" $ askTableInfoSource tableName
  let coreInfo = _tiCoreInfo tableInfo

  -- If it is view then check if it is updatable
  mutableView
    tableName
    viIsUpdatable
    (_tciViewInfo coreInfo)
    "updatable"

  -- Check if the role has update permissions
  updPerm <- askUpdPermInfo tableInfo

  -- Check if all dependent headers are present
  validateHeaders $ upiRequiredHeaders updPerm

  -- Check if select is allowed
  selPerm <-
    modifyErr (<> selNecessaryMsg) $
      askSelPermInfo tableInfo

  let fieldInfoMap = _tciFieldInfoMap coreInfo
      allCols = getCols fieldInfoMap
      preSetObj = upiSet updPerm
      preSetCols = M.keys preSetObj

  -- convert the object to SQL set expression
  setItems <-
    withPathK "$set" $
      convOp fieldInfoMap preSetCols updPerm (M.toList $ uqSet uq) $
        convSet prepValBldr

  incItems <-
    withPathK "$inc" $
      convOp fieldInfoMap preSetCols updPerm (M.toList $ uqInc uq) $
        convInc prepValBldr

  mulItems <-
    withPathK "$mul" $
      convOp fieldInfoMap preSetCols updPerm (M.toList $ uqMul uq) $
        convMul prepValBldr

  defItems <-
    withPathK "$default" $
      convOp fieldInfoMap preSetCols updPerm ((,()) <$> uqDefault uq) convDefault

  -- convert the returning cols into sql returing exp
  mAnnRetCols <- forM mRetCols $ \retCols ->
    withPathK "returning" $ checkRetCols fieldInfoMap selPerm retCols

  resolvedPreSetItems <-
    M.toList
      <$> mapM (convPartialSQLExp sessVarBldr) preSetObj

  let setExpItems =
        resolvedPreSetItems
          ++ setItems
          ++ incItems
          ++ mulItems
          ++ defItems

  when (null setExpItems) $
    throw400 UnexpectedPayload "atleast one of $set, $inc, $mul has to be present"

  -- convert the where clause
  annSQLBoolExp <-
    withPathK "where" $
      convBoolExp fieldInfoMap selPerm (uqWhere uq) sessVarBldr tableName prepValBldr

  resolvedUpdFltr <-
    convAnnBoolExpPartialSQL sessVarBldr $
      upiFilter updPerm
  resolvedUpdCheck <-
    fromMaybe gBoolExpTrue
      <$> traverse
        (convAnnBoolExpPartialSQL sessVarBldr)
        (upiCheck updPerm)

  return $
    AnnotatedUpdateG
      tableName
      (resolvedUpdFltr, annSQLBoolExp)
      resolvedUpdCheck
      (BackendUpdate $ Map.fromList $ fmap UpdateSet <$> setExpItems)
      (mkDefaultMutFlds mAnnRetCols)
      allCols
      Nothing
  where
    mRetCols = uqReturning uq
    selNecessaryMsg =
      "; \"update\" is only allowed if the role "
        <> "has \"select\" permission as \"where\" can't be used "
        <> "without \"select\" permission on the table"

validateUpdateQuery ::
  (QErrM m, UserInfoM m, CacheRM m) =>
  UpdateQuery ->
  m (AnnotatedUpdate ('Postgres 'Vanilla), DS.Seq PG.PrepArg)
validateUpdateQuery query = do
  let source = uqSource query
  tableCache :: TableCache ('Postgres 'Vanilla) <- fold <$> askTableCache source
  flip runTableCacheRT (source, tableCache) $
    runDMLP1T $
      validateUpdateQueryWith sessVarFromCurrentSetting (valueParserWithCollectableType binRHSBuilder) query

runUpdate ::
  forall m.
  ( QErrM m,
    UserInfoM m,
    CacheRM m,
    HasServerConfigCtx m,
    MonadBaseControl IO m,
    MonadIO m,
    Tracing.MonadTrace m,
    MetadataM m
  ) =>
  UpdateQuery ->
  m EncJSON
runUpdate q = do
  sourceConfig <- askSourceConfig @('Postgres 'Vanilla) (uqSource q)
  userInfo <- askUserInfo
  strfyNum <- stringifyNum . _sccSQLGenCtx <$> askServerConfigCtx
  validateUpdateQuery q
    >>= runTxWithCtx (_pscExecCtx sourceConfig) PG.ReadWrite
      . flip runReaderT emptyQueryTagsComment
      . execUpdateQuery strfyNum Nothing userInfo
