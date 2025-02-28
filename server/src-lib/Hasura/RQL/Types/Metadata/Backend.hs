module Hasura.RQL.Types.Metadata.Backend
  ( BackendMetadata (..),
  )
where

import Control.Arrow.Extended
import Control.Monad.Trans.Control (MonadBaseControl)
import Data.Aeson
import Data.Environment qualified as Env
import Hasura.Base.Error
import Hasura.GraphQL.Schema.NamingCase
import Hasura.Incremental qualified as Inc
import Hasura.Logging (Hasura, Logger)
import Hasura.Prelude
import Hasura.RQL.IR.BoolExp
import Hasura.RQL.Types.Backend
import Hasura.RQL.Types.BoolExp
import Hasura.RQL.Types.Column
import Hasura.RQL.Types.Common
import Hasura.RQL.Types.ComputedField
import Hasura.RQL.Types.EventTrigger
import Hasura.RQL.Types.Function
import Hasura.RQL.Types.Metadata
import Hasura.RQL.Types.Metadata.Object
import Hasura.RQL.Types.Relationships.Local
import Hasura.RQL.Types.SchemaCache
import Hasura.RQL.Types.SchemaCache.Build
import Hasura.RQL.Types.Source
import Hasura.RQL.Types.SourceCustomization
import Hasura.RQL.Types.Table
import Hasura.SQL.Backend
import Hasura.SQL.Types
import Hasura.Server.Migrate.Version
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.Manager (HasHttpManagerM)

class
  ( Backend b,
    Eq (AggregationPredicates b (PartialSQLExp b)),
    Eq (BooleanOperators b (PartialSQLExp b)),
    Eq (FunctionArgumentExp b (PartialSQLExp b)),
    Ord (BackendInvalidationKeys b),
    Hashable (AggregationPredicates b (PartialSQLExp b)),
    Hashable (BooleanOperators b (PartialSQLExp b)),
    Hashable (FunctionArgumentExp b (PartialSQLExp b)),
    Monoid (BackendInvalidationKeys b)
  ) =>
  BackendMetadata (b :: BackendType)
  where
  buildComputedFieldInfo ::
    (MonadError QErr m) =>
    HashSet (TableName b) ->
    TableName b ->
    HashSet (Column b) ->
    ComputedFieldName ->
    ComputedFieldDefinition b ->
    RawFunctionInfo b ->
    Comment ->
    m (ComputedFieldInfo b)

  fetchAndValidateEnumValues ::
    (MonadIO m, MonadBaseControl IO m) =>
    SourceConfig b ->
    TableName b ->
    Maybe (PrimaryKey b (RawColumnInfo b)) ->
    [RawColumnInfo b] ->
    m (Either QErr EnumValues)

  type BackendInvalidationKeys b
  type BackendInvalidationKeys b = ()

  resolveBackendInfo ::
    ( ArrowChoice arr,
      Inc.ArrowCache m arr,
      Inc.ArrowDistribute arr,
      ArrowWriter (Seq (Either InconsistentMetadata MetadataDependency)) arr,
      MonadIO m,
      HasHttpManagerM m
    ) =>
    Logger Hasura ->
    (Inc.Dependency (BackendInvalidationKeys b), BackendConfig b) `arr` BackendInfo b
  default resolveBackendInfo ::
    ( Arrow arr,
      BackendInfo b ~ ()
    ) =>
    Logger Hasura ->
    (Inc.Dependency (BackendInvalidationKeys b), BackendConfig b) `arr` BackendInfo b
  resolveBackendInfo = const $ arr $ const ()

  -- | Function that resolves the connection related source configuration, and
  -- creates a connection pool (and other related parameters) in the process
  resolveSourceConfig ::
    (MonadIO m, MonadResolveSource m) =>
    Logger Hasura ->
    SourceName ->
    SourceConnConfiguration b ->
    BackendSourceKind b ->
    BackendInfo b ->
    Env.Environment ->
    HTTP.Manager ->
    m (Either QErr (SourceConfig b))

  -- | Function that introspects a database for tables, columns, functions etc.
  resolveDatabaseMetadata ::
    (MonadIO m, MonadBaseControl IO m, MonadResolveSource m) =>
    SourceMetadata b ->
    SourceConfig b ->
    SourceTypeCustomization ->
    m (Either QErr (ResolvedSource b))

  parseBoolExpOperations ::
    (MonadError QErr m, TableCoreInfoRM b m) =>
    ValueParser b m v ->
    TableName b ->
    FieldInfoMap (FieldInfo b) ->
    ColumnReference b ->
    Value ->
    m [OpExpG b v]

  buildFunctionInfo ::
    (MonadError QErr m) =>
    SourceName ->
    FunctionName b ->
    SystemDefined ->
    FunctionConfig ->
    FunctionPermissionsMap ->
    RawFunctionInfo b ->
    -- | the function comment
    Maybe Text ->
    NamingCase ->
    m (FunctionInfo b, SchemaDependency)

  updateColumnInEventTrigger ::
    TableName b ->
    Column b ->
    Column b ->
    TableName b ->
    EventTriggerConf b ->
    EventTriggerConf b

  parseCollectableType ::
    (MonadError QErr m) =>
    CollectableType (ColumnType b) ->
    Value ->
    m (PartialSQLExp b)

  postDropSourceHook ::
    (MonadError QErr m, MonadIO m, MonadBaseControl IO m) =>
    SourceConfig b ->
    TableEventTriggers b ->
    m ()

  -- TODO: rename?
  validateRelationship ::
    MonadError QErr m =>
    TableCache b ->
    TableName b ->
    Either (ObjRelDef b) (ArrRelDef b) ->
    m ()
  default validateRelationship ::
    MonadError QErr m =>
    TableCache b ->
    TableName b ->
    Either (ObjRelDef b) (ArrRelDef b) ->
    m ()
  validateRelationship _ _ _ = pure ()

  -- | Function that that builds a boolean expression field out of a computed field
  buildComputedFieldBooleanExp ::
    ( MonadError QErr m,
      TableCoreInfoRM b m
    ) =>
    BoolExpResolver b m v ->
    BoolExpRHSParser b m v ->
    TableName b ->
    FieldInfoMap (FieldInfo b) ->
    ComputedFieldInfo b ->
    Value ->
    m (AnnComputedFieldBoolExp b v)

  -- | Run all operations required to create, update, or migrate the internal
  -- catalog used by the backend for internal bookkeeping, if any. The return
  -- type indicates whether the performed operations subsequently require
  -- re-creating event trigers.
  prepareCatalog ::
    (MonadIO m, MonadBaseControl IO m) =>
    SourceConfig b ->
    ExceptT QErr m (RecreateEventTriggers, SourceCatalogMigrationState)
