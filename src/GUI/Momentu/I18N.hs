{-# LANGUAGE TemplateHaskell #-}

module GUI.Momentu.I18N where

import qualified Control.Lens as Lens
import qualified Data.Aeson.TH.Extended as JsonTH

import           Lamdu.Prelude

data Texts a = Texts
    { _edit :: a
    , _view :: a
    , _insert :: a
    , _delete :: a
    } deriving Eq
Lens.makeLenses ''Texts
JsonTH.derivePrefixed "_" ''Texts
