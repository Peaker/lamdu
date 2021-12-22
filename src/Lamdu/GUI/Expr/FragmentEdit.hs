module Lamdu.GUI.Expr.FragmentEdit
    ( make
    ) where

import qualified Control.Lens as Lens
import qualified GUI.Momentu as M
import qualified GUI.Momentu.Animation as Anim
import qualified GUI.Momentu.Direction as Dir
import qualified GUI.Momentu.Element as Element
import qualified GUI.Momentu.EventMap as E
import qualified GUI.Momentu.I18N as MomentuTexts
import           GUI.Momentu.ModKey (noMods)
import qualified GUI.Momentu.ModKey as ModKey
import           GUI.Momentu.Responsive (Responsive(..))
import qualified GUI.Momentu.Responsive as Responsive
import qualified GUI.Momentu.Responsive.Expression as ResponsiveExpr
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.Label as Label
import qualified GUI.Momentu.Widgets.Menu as Menu
import qualified GUI.Momentu.Widgets.Menu.Search as SearchMenu
import qualified GUI.Momentu.Widgets.Spacer as Spacer
import qualified Lamdu.Config as Config
import qualified Lamdu.Config.Theme as Theme
import qualified Lamdu.Config.Theme.ValAnnotation as ValAnnotation
import           Lamdu.GUI.Annotation (addInferredType, shrinkValAnnotationsIfNeeded)
import qualified Lamdu.GUI.Expr.ApplyEdit as ApplyEdit
import qualified Lamdu.GUI.Expr.EventMap as ExprEventMap
import qualified Lamdu.GUI.Expr.GetVarEdit as GetVarEdit
import qualified Lamdu.GUI.Expr.InjectEdit as InjectEdit
import qualified Lamdu.GUI.Expr.NominalEdit as NominalEdit
import           Lamdu.GUI.Expr.OptionEdit
import           Lamdu.GUI.Monad (GuiM)
import qualified Lamdu.GUI.Monad as GuiM
import           Lamdu.GUI.Styled (label, grammar)
import qualified Lamdu.GUI.TagView as TagView
import qualified Lamdu.GUI.Types as ExprGui
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.GUI.Wrap (stdWrapParentExpr, stdWrap)
import qualified Lamdu.I18N.Code as Texts
import qualified Lamdu.I18N.CodeUI as Texts
import           Lamdu.Name (Name)
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

allowedSearchTerm :: (MonadReader env m, Has Dir.Layout env) => m (Text -> Bool)
allowedSearchTerm =
    do
        as <- ExprEventMap.allowedSearchTerm
        recordOpener <- ExprEventMap.recordOpener
        let isWrapInRec x =
                case x ^? Lens._Cons of
                Nothing -> False
                Just (p, r) -> p == recordOpener && ExprEventMap.isAlphaNumericName r
        pure (\x -> as x || isWrapInRec x)

make :: _ => ExprGui.Expr Sugar.Fragment i o -> GuiM env i o (Responsive o)
make (Ann (Const pl) fragment) =
    do
        fragmentExprGui <- fragment ^. Sugar.fExpr & GuiM.makeSubexpression

        env <- Lens.view id
        let healDoc = E.toDoc env editFragmentHeal
        let delHealsEventMap =
                E.keysEventMapMovesCursor (Config.delKeys env) healDoc healAction
        let healEventMap =
                E.keysEventMapMovesCursor (env ^. has . Config.healKeys) healDoc healAction <>
                ExprEventMap.closeParenEvent editFragmentHeal healAction env

        as <- allowedSearchTerm
        searchMenu <-
            SearchMenu.make
            (SearchMenu.searchTermEdit menuId (pure . as))
            (makeResults (fragment ^. Sugar.fOptions)) M.empty menuId
            ?? Menu.AnyPlace
            & local (has . SearchMenu.emptyStrings . Lens.mapped .~ "?")
            -- Space goes to next hole in target (not necessarily visible)
            & local (has . Menu.configKeysPickOptionAndGotoNext <>~ [noMods ModKey.Key'Space])
            <&> Lens.mapped %~ Widget.weakerEventsWithoutPreevents delHealsEventMap
        hbox <- ResponsiveExpr.boxSpacedMDisamb ?? ExprGui.mParensId pl

        addInnerType <-
            case fragment ^. Sugar.fTypeMismatch of
            Nothing -> pure id
            Just mismatchedType ->
                do
                    color <- Lens.view (has . Theme.errorColor)
                    animId <- Element.subAnimId ?? ["err-line"]
                    spacing <- Lens.view
                        (has . Theme.valAnnotation . ValAnnotation.valAnnotationSpacing)
                    stdFontHeight <- Spacer.stdFontHeight
                    addInferredType mismatchedType shrinkValAnnotationsIfNeeded
                        <&> (lineBelow color animId (spacing * stdFontHeight) .)
            & Element.locallyAugmented ("inner type"::Text)

        hbox
            [ fragmentExprGui
            , Responsive.fromWithTextPos searchMenu
            ]
            & Widget.widget %~ addInnerType
            & pure & stdWrapParentExpr pl
            <&> Widget.weakerEventsWithoutPreevents healEventMap
    where
        editFragmentHeal = [has . MomentuTexts.edit, has . Texts.fragment, has . Texts.heal]
        healAction = fragment ^. Sugar.fHeal <&> WidgetIds.fromEntityId
        menuId = WidgetIds.fromExprPayload pl & WidgetIds.fragmentHoleId
        lineBelow color animId spacing ann =
            ann
            & Element.setLayeredImage . Element.layers . Lens.ix 0 %~ (<> line)
            where
                line =
                    Anim.coloredRectangle animId color
                    & Anim.scale (M.Vector2 (ann ^. Element.width) spacing)
                    & Anim.translate (M.Vector2 0 (ann ^. Element.height))

makeResults ::
    _ =>
    i (Sugar.Query -> i [Sugar.Option Sugar.FragOpt Name i o]) ->
    SearchMenu.ResultsContext ->
    GuiM env i o (Menu.OptionList (Menu.Option (GuiM env i o) o))
makeResults opts ctx =
    do
        c <- Lens.view (has . Config.completion . Config.completionResultCount)
        GuiM.im opts <*>
            makeQuery ctx
            >>= GuiM.im
            <&> take c
            <&> Lens.mapped %~ makeResult makeFragOpt ctx
            <&> Menu.OptionList isTruncated
    where
        isTruncated = False -- TODO: Need to specify whether we have more options

makeFragOpt :: _ => ExprGui.Expr Sugar.FragOpt i o -> GuiM env i o (Responsive o)
makeFragOpt (Ann (Const a) b) =
    case b of
    Sugar.FragPostfix x ->
        (ResponsiveExpr.boxSpacedMDisamb ?? Nothing)
        <*> traverse ApplyEdit.makePostfixFunc x
    Sugar.FragInject x -> InjectEdit.make (Ann (Const a) (Const x))
    Sugar.FragGetVar x -> GetVarEdit.make (Ann (Const a) (Const x))
    Sugar.FragOp x -> makeFragOperator x
    Sugar.FragToNom x -> NominalEdit.makeTIdView x & fromView
    Sugar.FragIf t ->
        (grammar (label Texts.if_) M./|/ grammar (Label.make ":")) M./|/
        Spacer.stdHSpace M./|/ GuiM.makeSubexpression t
    Sugar.FragLam -> grammar (label Texts.lam) & fromView
    Sugar.FragDefer -> grammar (label Texts.defer) & fromView
    Sugar.FragWrapInRec x ->
        grammar (label Texts.recordOpener) M./|/ TagView.make (x ^. Sugar.tagRefTag) & fromView
    -- Reproduction of behaviour from Lamdu.GUI.Expr.make,
    -- otherwise fragment editors would have clashing anim ids
    & local (M.animIdPrefix .~ Widget.toAnimId myId)
    where
        myId = WidgetIds.fromExprPayload a
        fromView act = (Widget.makeFocusableWidget ?? myId <&> (Widget.widget %~)) <*> (act <&> Responsive.fromTextView) & stdWrap a

makeFragOperator :: _ => ExprGui.Body Sugar.FragOperator i o -> GuiM env i o (Responsive o)
makeFragOperator (Sugar.FragOperator f arg) = ApplyEdit.makeOperatorRow id f arg
