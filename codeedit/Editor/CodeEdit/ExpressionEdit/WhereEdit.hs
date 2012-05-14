{-# LANGUAGE OverloadedStrings #-}
module Editor.CodeEdit.ExpressionEdit.WhereEdit(make, makeWithBody) where

import Control.Arrow (second)
import Control.Monad (liftM)
import Data.Monoid (mempty)
import Editor.Anchors (ViewTag)
import Editor.CTransaction (TWidget, atTextSizeColor, assignCursor)
import Editor.CodeEdit.ExpressionEdit.ExpressionMaker(ExpressionEditMaker)
import Editor.MonadF (MonadF)
import qualified Editor.BottleWidgets as BWidgets
import qualified Editor.CodeEdit.DefinitionEdit as DefinitionEdit
import qualified Editor.CodeEdit.Sugar as Sugar
import qualified Editor.Config as Config
import qualified Editor.WidgetIds as WidgetIds
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widgets.Grid as Grid

make
  :: MonadF m
  => ExpressionEditMaker m
  -> Sugar.Where m
  -> Widget.Id -> TWidget ViewTag m
make makeExpressionEdit (Sugar.Where items _) myId = do
    whereLabel <-
      atTextSizeColor Config.whereTextSize Config.whereColor $
      BWidgets.makeLabel "where" myId
    whereEdits <- makeWhereItemsGrid
    return . BWidgets.vbox $
      [ whereLabel
      , Widget.scale Config.whereScaleFactor whereEdits
      ]
  where
    makeWhereItemsGrid = liftM (Grid.toWidget . addJumps . Grid.makeKeyed) $ mapM makeWhereItemEdits items
    addJumps = (Grid.atGridContent . fmap . map) DefinitionEdit.addJumps
    makeWhereItemEdits item =
      (liftM . map . second) (Widget.weakerEvents (whereItemDeleteEventMap item)) $
      DefinitionEdit.makeParts makeExpressionEdit
      (paramId item) (guid item) (Sugar.wiValue item)
    paramId = WidgetIds.paramId . guid
    guid = Sugar.guid . Sugar.wiActions
    whereItemDeleteEventMap whereItem =
      maybe mempty
      (Widget.actionEventMapMovesCursor Config.delKeys "Delete variable" . liftM WidgetIds.fromGuid)
      (Sugar.mDelete (Sugar.wiActions whereItem))

makeWithBody
  :: MonadF m
  => ExpressionEditMaker m
  -> Sugar.Where m
  -> Widget.Id -> TWidget ViewTag m
makeWithBody makeExpressionEdit where_@(Sugar.Where _ body) myId = do
  whereEdit <- make makeExpressionEdit where_ myId
  assignCursor myId ((WidgetIds.fromGuid . Sugar.guid . Sugar.rActions) body) $ do
    bodyEdit <- makeExpressionEdit body
    return . BWidgets.vbox $
      [ bodyEdit
      , whereEdit
      ]
