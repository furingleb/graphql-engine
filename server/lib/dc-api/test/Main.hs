module Main (main) where

--------------------------------------------------------------------------------

import Command (Command (..), TestOptions (..), parseCommandLine)
import Control.Exception (throwIO)
import Control.Monad (join, (>=>))
import Data.Aeson.Text (encodeToLazyText)
import Data.Fix (Fix (..), foldFix)
import Data.Foldable (for_, traverse_)
import Data.Proxy (Proxy (..))
import Data.Text.Lazy.IO qualified as Text
import Hasura.Backends.DataConnector.API (Routes (..), apiClient, openApiSchema)
import Hasura.Backends.DataConnector.API qualified as API
import Hasura.Backends.DataConnector.API.V0.Capabilities as API
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Servant.API (NamedRoutes)
import Servant.Client (Client, ClientError, hoistClient, mkClientEnv, runClientM)
import Test.CapabilitiesSpec qualified
import Test.ConfigSpec qualified
import Test.Data (TestData, guardedCapabilities, mkTestData)
import Test.DataExport (exportData)
import Test.ErrorSpec qualified
import Test.ExplainSpec qualified
import Test.HealthSpec qualified
import Test.Hspec (Spec)
import Test.Hspec.Core.Runner (evalSpec, runSpec)
import Test.Hspec.Core.Spec (Item (itemRequirement), SpecTree, Tree (..))
import Test.Hspec.Core.Util (filterPredicate)
import Test.Hspec.Runner (Config (..), Path, defaultConfig, evaluateSummary)
import Test.MetricsSpec qualified
import Test.QuerySpec qualified
import Test.SchemaSpec qualified
import Prelude

--------------------------------------------------------------------------------

testSourceName :: API.SourceName
testSourceName = "dc-api-tests"

tests :: TestData -> Client IO (NamedRoutes Routes) -> API.SourceName -> API.Config -> API.CapabilitiesResponse -> Spec
tests testData api sourceName agentConfig capabilitiesResponse = do
  let capabilities = API._crCapabilities capabilitiesResponse
  let configSchema = API._crConfigSchemaResponse capabilitiesResponse
  Test.HealthSpec.spec api sourceName agentConfig
  Test.ConfigSpec.spec agentConfig configSchema
  Test.CapabilitiesSpec.spec api agentConfig capabilities
  Test.SchemaSpec.spec testData api sourceName agentConfig capabilities
  Test.QuerySpec.spec testData api sourceName agentConfig capabilities
  Test.ErrorSpec.spec testData api sourceName agentConfig capabilities
  for_ (API._cMetrics capabilities) \m -> Test.MetricsSpec.spec api m
  for_ (API._cExplain capabilities) \_ -> Test.ExplainSpec.spec testData api sourceName agentConfig capabilities

main :: IO ()
main = do
  command <- parseCommandLine
  case command of
    Test testOptions@TestOptions {..} -> do
      api <- mkIOApiClient testOptions
      agentCapabilities <- guardedCapabilities api
      let testData = mkTestData _toTestConfig
      let spec = tests testData api testSourceName _toAgentConfig agentCapabilities
      case _toExportMatchStrings of
        False -> runSpec spec (applyTestConfig defaultConfig testOptions) >>= evaluateSummary
        True -> do
          tree <- fmap snd $ evalSpec defaultConfig spec
          traverse_ ((traverse_ putStrLn) . (foldPaths . extractLabels)) tree
    ExportOpenAPISpec ->
      Text.putStrLn $ encodeToLazyText openApiSchema
    ExportData config ->
      exportData config

  pure ()

mkIOApiClient :: TestOptions -> IO (Client IO (NamedRoutes Routes))
mkIOApiClient TestOptions {..} = do
  manager <- newManager defaultManagerSettings
  let clientEnv = mkClientEnv manager _toAgentBaseUrl
  pure $ hoistClient (Proxy @(NamedRoutes Routes)) (flip runClientM clientEnv >=> throwClientError) apiClient

throwClientError :: Either ClientError a -> IO a
throwClientError = either throwIO pure

applyTestConfig :: Config -> TestOptions -> Config
applyTestConfig config TestOptions {..} =
  config
    { configConcurrentJobs = _toParallelDegree,
      configFilterPredicate = filterPredicate <$> _toMatch,
      configSkipPredicate = filterPredicates _toSkip,
      configDryRun = _toDryRun
    }

filterPredicates :: [String] -> Maybe (Path -> Bool)
filterPredicates [] = Nothing
filterPredicates xs = Just (\p -> any ($ p) (filterPredicate <$> xs))

--------------------------------------------------------------------------------

data TreeF r = NodeF String [r] | LeafF String
  deriving (Show, Functor)

-- | Fold a tree into a list of paths.
--
-- Note: we use @foldFix@ here because it is guaranteed to terminate and
-- bottom up recursion drastically simplifies the algorithm.
foldPaths :: Fix TreeF -> [String]
foldPaths = foldFix \case
  NodeF label paths -> fmap ((label <>) . ('/' :)) $ join paths
  LeafF label -> [label]

-- | Load the spec descriptions into a 'TreeF'
extractLabels :: SpecTree a -> Fix TreeF
extractLabels = \case
  Node s trs -> Fix $ NodeF s (fmap extractLabels trs)
  NodeWithCleanup ma _ trs -> Fix $ NodeF (foldMap fst ma) (fmap extractLabels trs)
  Leaf it -> Fix $ LeafF $ itemRequirement it
