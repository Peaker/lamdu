module Lamdu.GUI.Expr.BuiltinEdit
    ( make
    ) where

import qualified Control.Lens as Lens
import qualified Control.Monad.Reader as Reader
import           Data.Property (Property(..))
import qualified Data.Text as Text
import qualified GUI.Momentu as M
import qualified GUI.Momentu.EventMap as E
import qualified GUI.Momentu.I18N as MomentuTexts
import           GUI.Momentu.MetaKey (MetaKey(..), noMods)
import qualified GUI.Momentu.MetaKey as MetaKey
import qualified GUI.Momentu.State as GuiState
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.FocusDelegator as FocusDelegator
import qualified GUI.Momentu.Widgets.Label as Label
import qualified GUI.Momentu.Widgets.TextEdit as TextEdit
import qualified GUI.Momentu.Widgets.TextEdit.Property as TextEdits
import qualified GUI.Momentu.Widgets.TextView as TextView
import qualified Lamdu.Config.Theme as Theme
import qualified Lamdu.Config.Theme.TextColors as TextColors
import qualified Lamdu.Data.Definition as Definition
import qualified Lamdu.I18N.CodeUI as Texts
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

builtinFDConfig :: _ => env -> FocusDelegator.Config
builtinFDConfig env = FocusDelegator.Config
    { FocusDelegator.focusChildKeys = [MetaKey noMods MetaKey.Key'Enter]
    , FocusDelegator.focusChildDoc = doc Texts.changeImportedName
    , FocusDelegator.focusParentKeys = [MetaKey noMods MetaKey.Key'Escape]
    , FocusDelegator.focusParentDoc = doc Texts.doneChangingImportedName
    }
    where
        doc lens = E.toDoc env [has . MomentuTexts.edit, has . lens]

builtinFFIPath :: Widget.Id -> Widget.Id
builtinFFIPath = flip Widget.joinId ["FFIPath"]

builtinFFIName :: Widget.Id -> Widget.Id
builtinFFIName = flip Widget.joinId ["FFIName"]

makeNamePartEditor ::
    _ => M.Color -> Text -> (Text -> f ()) -> Widget.Id -> m (M.TextWidget f)
makeNamePartEditor color namePartStr setter myId =
    (FocusDelegator.make
        <*> (Lens.view id <&> builtinFDConfig)
        ?? FocusDelegator.FocusEntryParent
        ?? myId <&> (M.tValue %~))
    <*> ( TextEdits.makeWordEdit ?? empty ?? Property namePartStr setter ??
          myId `Widget.joinId` ["textedit"]
        )
    & Reader.local (TextView.color .~ color)
    where
        empty =
            TextEdit.Modes
            { TextEdit._unfocused = "(?)"
            , TextEdit._focused = ""
            }

make :: _ => Sugar.DefinitionBuiltin name o -> Widget.Id -> f (M.TextWidget o)
make def myId =
    do
        colors <- Lens.view (has . Theme.textColors)
        makeNamePartEditor (colors ^. TextColors.foreignModuleColor)
            modulePathStr modulePathSetter (builtinFFIPath myId)
            M./|/ Label.make "."
            M./|/ makeNamePartEditor (colors ^. TextColors.foreignVarColor) name
            nameSetter (builtinFFIName myId)
    & GuiState.assignCursor myId (builtinFFIName myId)
    where
        Sugar.DefinitionBuiltin
            (Definition.FFIName modulePath name) setFFIName _ = def
        modulePathStr = Text.intercalate "." modulePath
        modulePathSetter = setFFIName . (`Definition.FFIName` name) . Text.splitOn "."
        nameSetter = setFFIName . Definition.FFIName modulePath
