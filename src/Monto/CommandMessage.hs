{-# LANGUAGE TemplateHaskell #-}
module Monto.CommandMessage where

import           Data.Aeson        (Value)
import           Data.Aeson.Casing (snakeCase)
import           Data.Aeson.TH
import           Data.Text         (Text)
import           Prelude           hiding (id)

import           Monto.Types

data CommandMessage =
  CommandMessage
    { id        :: Int
    , session   :: Int
    , serviceID :: ServiceID
    , tag       :: Text
    , contents  :: Value
    } deriving (Show)

-- TODO instances correct?
instance Ord CommandMessage where
  compare x y = compare (id x) (id y)

instance Eq CommandMessage where
  x == y = id x == id y

$(deriveJSON (defaultOptions {
  fieldLabelModifier = snakeCase
}) ''CommandMessage)
