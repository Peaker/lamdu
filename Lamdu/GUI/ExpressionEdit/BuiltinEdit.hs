module Lamdu.GUI.ExpressionEdit.BuiltinEdit(make) where

import           Control.Lens.Operators
import           Control.MonadA (MonadA)
import qualified Data.List as List
import           Data.List.Split (splitOn)
import           Data.Monoid (Monoid(..))
import           Data.Store.Property (Property(..))
import           Data.Store.Transaction (Transaction)
import qualified Graphics.UI.Bottle.EventMap as E
import           Graphics.UI.Bottle.ModKey (ModKey(..))
import           Graphics.UI.Bottle.Widget (Widget)
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widgets.Box as Box
import qualified Graphics.UI.Bottle.Widgets.FocusDelegator as FocusDelegator
import qualified Graphics.UI.GLFW as GLFW
import qualified Lamdu.Config as Config
import qualified Lamdu.Data.Definition as Definition
import qualified Lamdu.GUI.BottleWidgets as BWidgets
import           Lamdu.GUI.ExpressionGui.Monad (ExprGuiM)
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import qualified Lamdu.GUI.WidgetEnvT as WE
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import qualified Lamdu.Sugar.Types as Sugar

type T = Transaction

builtinFDConfig :: FocusDelegator.Config
builtinFDConfig = FocusDelegator.Config
    { FocusDelegator.focusChildKeys = [ModKey mempty GLFW.Key'Enter]
    , FocusDelegator.focusChildDoc = E.Doc ["Edit", "Change imported name"]
    , FocusDelegator.focusParentKeys = [ModKey mempty GLFW.Key'Escape]
    , FocusDelegator.focusParentDoc = E.Doc ["Edit", "Stop changing name"]
    }

make ::
    MonadA m =>
    Sugar.DefinitionBuiltin m ->
    Widget.Id ->
    ExprGuiM m (Widget (T m))
make (Sugar.DefinitionBuiltin (Definition.FFIName modulePath name) setFFIName _) myId =
    ExprGuiM.assignCursor myId (WidgetIds.builtinFFIName myId) $ do
        config <- ExprGuiM.widgetEnv WE.readConfig
        moduleName <-
            makeNamePartEditor (Config.foreignModuleColor config)
            modulePathStr modulePathSetter WidgetIds.builtinFFIPath
        varName <-
            makeNamePartEditor (Config.foreignVarColor config) name nameSetter
            WidgetIds.builtinFFIName
        dot <- ExprGuiM.makeLabel "." $ Widget.toAnimId myId
        Box.hboxCentered [moduleName, dot, varName] & return
    where
        mkWordEdit color prop wId =
            BWidgets.makeWordEdit prop wId
            & ExprGuiM.widgetEnv
            & ExprGuiM.withFgColor color
        makeNamePartEditor color namePartStr setter makeWidgetId =
            mkWordEdit color (Property namePartStr setter)
            & ExprGuiM.wrapDelegated builtinFDConfig FocusDelegator.NotDelegating id
            $ makeWidgetId myId
        modulePathStr = List.intercalate "." modulePath
        modulePathSetter = setFFIName . (`Definition.FFIName` name) . splitOn "."
        nameSetter = setFFIName . Definition.FFIName modulePath
