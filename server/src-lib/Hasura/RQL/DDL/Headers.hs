module Hasura.RQL.DDL.Headers
  ( HeaderConf (..),
    HeaderValue (HVEnv, HVValue),
    makeHeadersFromConf,
    toHeadersConf,
  )
where

import Data.Aeson
import Data.CaseInsensitive qualified as CI
import Data.Environment qualified as Env
import Data.Text qualified as T
import Hasura.Base.Error
import Hasura.Base.Instances ()
import Hasura.Prelude
import Network.HTTP.Types qualified as HTTP

data HeaderConf = HeaderConf HeaderName HeaderValue
  deriving (Show, Eq, Generic)

instance NFData HeaderConf

instance Hashable HeaderConf

type HeaderName = Text

data HeaderValue = HVValue Text | HVEnv Text
  deriving (Show, Eq, Generic)

instance NFData HeaderValue

instance Hashable HeaderValue

instance FromJSON HeaderConf where
  parseJSON (Object o) = do
    name <- o .: "name"
    value <- o .:? "value"
    valueFromEnv <- o .:? "value_from_env"
    case (value, valueFromEnv) of
      (Nothing, Nothing) -> fail "expecting value or value_from_env keys"
      (Just val, Nothing) -> return $ HeaderConf name (HVValue val)
      (Nothing, Just val) -> do
        when (T.isPrefixOf "HASURA_GRAPHQL_" val) $
          fail $
            "env variables starting with \"HASURA_GRAPHQL_\" are not allowed in value_from_env: " <> T.unpack val
        return $ HeaderConf name (HVEnv val)
      (Just _, Just _) -> fail "expecting only one of value or value_from_env keys"
  parseJSON _ = fail "expecting object for headers"

instance ToJSON HeaderConf where
  toJSON (HeaderConf name (HVValue val)) = object ["name" .= name, "value" .= val]
  toJSON (HeaderConf name (HVEnv val)) = object ["name" .= name, "value_from_env" .= val]

-- | Resolve configuration headers
makeHeadersFromConf ::
  MonadError QErr m => Env.Environment -> [HeaderConf] -> m [HTTP.Header]
makeHeadersFromConf env = mapM getHeader
  where
    getHeader hconf =
      ((CI.mk . txtToBs) *** txtToBs)
        <$> case hconf of
          (HeaderConf name (HVValue val)) -> return (name, val)
          (HeaderConf name (HVEnv val)) -> do
            let mEnv = Env.lookupEnv env (T.unpack val)
            case mEnv of
              Nothing -> throw400 NotFound $ "environment variable '" <> val <> "' not set"
              Just envval -> pure (name, T.pack envval)

-- | Encode headers to HeaderConf
toHeadersConf :: [HTTP.Header] -> [HeaderConf]
toHeadersConf =
  map (uncurry HeaderConf . ((bsToTxt . CI.original) *** (HVValue . bsToTxt)))
