module Lamdu.GUI.Expr.BinderEdit
    ( make
    ) where

import qualified Control.Lens as Lens
import qualified Control.Monad.Reader as Reader
import qualified GUI.Momentu as M
import qualified GUI.Momentu.EventMap as E
import qualified GUI.Momentu.I18N as MomentuTexts
import           GUI.Momentu.Responsive (Responsive)
import qualified GUI.Momentu.Responsive as Responsive
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.Spacer as Spacer
import qualified Lamdu.Config as Config
import qualified Lamdu.Config.Theme as Theme
import qualified Lamdu.Config.Theme.TextColors as TextColors
import qualified Lamdu.GUI.Expr.AssignmentEdit as AssignmentEdit
import qualified Lamdu.GUI.Expr.EventMap as ExprEventMap
import           Lamdu.GUI.Monad (GuiM)
import qualified Lamdu.GUI.Monad as GuiM
import           Lamdu.GUI.Styled (grammar, label)
import qualified Lamdu.GUI.Types as ExprGui
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.GUI.Wrap (stdWrapParentExpr)
import qualified Lamdu.I18N.Code as Texts
import qualified Lamdu.I18N.CodeUI as CodeUI
import qualified Lamdu.I18N.Definitions as Definitions
import qualified Lamdu.I18N.Navigation as Texts
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

makeLetEdit :: _ => ExprGui.Body Sugar.Let i o -> GuiM env i o (Responsive o)
makeLetEdit item =
    do
        env <- Lens.view id
        let eventMap =
                foldMap
                ( E.keysEventMapMovesCursor (env ^. has . Config.extractKeys)
                    (E.toDoc env
                        [ has . MomentuTexts.edit
                        , has . CodeUI.letClause
                        , has . Definitions.extractToOuter
                        ])
                    . fmap ExprEventMap.extractCursor
                ) (item ^? Sugar.lValue . annotation . _1 . Sugar.plActions . Sugar.extract)
                <>
                E.keysEventMapMovesCursor (Config.delKeys env)
                (E.toDoc env
                    [ has . MomentuTexts.edit
                    , has . CodeUI.letClause
                    , has . MomentuTexts.delete
                    ])
                (bodyId <$ item ^. Sugar.lDelete)
                <>
                foldMap
                ( E.keysEventMapMovesCursor (env ^. has . Config.inlineKeys)
                    (E.toDoc env
                        [ has . MomentuTexts.navigation
                        , has . Texts.jumpToFirstUse
                        ])
                    . pure . WidgetIds.fromEntityId
                ) (item ^? Sugar.lUsages . Lens.ix 0)
        grammar (label Texts.let_)
            M./|/ Spacer.stdHSpace
            M./|/ (AssignmentEdit.make Nothing (item ^. Sugar.lName)
                    TextColors.letColor binder
                    <&> M.weakerEvents eventMap
                    <&> M.padAround (env ^. has . Theme.letItemPadding))
    where
        bodyId = item ^. Sugar.lBody . annotation . _1 & WidgetIds.fromExprPayload
        binder = item ^. Sugar.lValue

make :: _ => ExprGui.Expr Sugar.Binder i o -> GuiM env i o (Responsive o)
make (Ann (Const pl) (Sugar.BinderTerm assignmentBody)) =
    Ann (Const pl) assignmentBody & GuiM.makeSubexpression
make (Ann (Const pl) (Sugar.BinderLet l)) =
    do
        env <- Lens.view id
        let moveToInnerEventMap =
                body
                ^? hVal . Sugar._BinderLet
                . Sugar.lValue . annotation . _1 . Sugar.plActions
                . Sugar.extract
                & foldMap
                (E.keysEventMap (env ^. has . Config.moveLetInwardKeys)
                (E.toDoc env
                    [ has . MomentuTexts.edit
                    , has . CodeUI.letClause
                    , has . Texts.moveInwards
                    ]) . void)
        Responsive.vboxSpaced
            <*>
            sequence
            [ makeLetEdit l <&> M.weakerEvents moveToInnerEventMap
            , make body
            ]
        & stdWrapParentExpr pl
        & Reader.local (M.animIdPrefix .~ Widget.toAnimId myId)
    where
        myId = WidgetIds.fromExprPayload (pl ^. _1)
        body = l ^. Sugar.lBody
