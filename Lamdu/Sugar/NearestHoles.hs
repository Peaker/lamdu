{-# LANGUAGE TemplateHaskell, RankNTypes #-}
module Lamdu.Sugar.NearestHoles
  ( NearestHoles(..), prev, next
  , none
  , add
  ) where

import Control.Applicative.Utils (when)
import Control.Lens (LensLike)
import Control.Lens.Operators
import Control.Lens.Tuple
import Control.Monad.Trans.State (State, evalState)
import Control.MonadA (MonadA)
import qualified Control.Lens as Lens
import qualified Control.Monad.Trans.State as State
import qualified Lamdu.Sugar.Lens as SugarLens
import qualified Lamdu.Sugar.Types as Sugar

markStoredHoles ::
  Sugar.Expression name m a ->
  Sugar.Expression name m (Bool, a)
markStoredHoles expr =
  expr
  <&> Sugar.plData %~ (,) False
  & SugarLens.holePayloads . Sugar.plData . _1 .~ True
  <&> removeNonStoredMarks
  where
    removeNonStoredMarks pl =
      case pl ^. Sugar.plActions of
      Nothing -> pl & Sugar.plData . _1 .~ False
      Just _ -> pl

data NearestHoles = NearestHoles
  { _prev :: Maybe Sugar.EntityId
  , _next :: Maybe Sugar.EntityId
  } deriving (Eq, Show)
Lens.makeLenses ''NearestHoles

none :: NearestHoles
none = NearestHoles Nothing Nothing

add ::
  MonadA m =>
  (forall a b.
   Lens.Traversal (f a) (f b)
   (Sugar.Expression name m a)
   (Sugar.Expression name m b)) ->
  f (NearestHoles -> r) -> f r
add exprs s =
  s
  & exprs . Lens.mapped . Sugar.plData %~ toNearestHoles
  & exprs %~ markStoredHoles
  & passAll (exprs . Lens.traverse)
  & passAll (Lens.backwards (exprs . Lens.traverse))
  & exprs . Lens.mapped . Sugar.plData %~ snd
  where
    toNearestHoles f prevHole nextHole = f (NearestHoles prevHole nextHole)

type M = State (Maybe Sugar.EntityId)

passAll ::
  LensLike M s t
  (Sugar.Payload m (Bool, Maybe Sugar.EntityId -> a))
  (Sugar.Payload m (Bool, a)) -> s -> t
passAll sugarPls s =
  s
  & sugarPls %%~ setEntityId
  & (`evalState` Nothing)

setEntityId ::
  Sugar.Payload m (Bool, Maybe Sugar.EntityId -> a) ->
  M (Sugar.Payload m (Bool, a))
setEntityId pl =
  do
    oldEntityId <- State.get
    when isStoredHole $ State.put $ Just $ pl ^. Sugar.plEntityId
    pl
      & Sugar.plData . _2 %~ ($ oldEntityId)
      & return
  where
    isStoredHole = pl ^. Sugar.plData . _1
