module Lamdu.GUI.Expr.GetFieldEdit
    ( make
    ) where

import           GUI.Momentu (Responsive, (/|/))
import qualified GUI.Momentu.Responsive as Responsive
import qualified GUI.Momentu.Widgets.Label as Label
import qualified Lamdu.Config.Theme.TextColors as TextColors
import qualified Lamdu.GUI.Expr.TagEdit as TagEdit
import           Lamdu.GUI.Monad (GuiM)
import qualified Lamdu.GUI.Styled as Styled
import           Lamdu.Name (Name)
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

make :: _ => Sugar.TagRef Name i o -> GuiM env i o (Responsive o)
make tag =
    Styled.grammar (Label.make ".")
    /|/ TagEdit.makeColoredTag TextColors.recordTagColor (const Nothing) tag
    <&> Responsive.fromWithTextPos
