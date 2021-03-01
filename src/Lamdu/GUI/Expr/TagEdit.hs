module Lamdu.GUI.Expr.TagEdit
    ( makeRecordTag, makeVariantTag
    , makeParamTag, addParamId
    , makeArgTag
    , makeTagHoleEdit
    , makeBinderTagEdit
    ) where

import qualified Control.Lens as Lens
import qualified Control.Monad.Reader as Reader
import qualified Data.Char as Char
import           Data.MRUMemo (memo)
import qualified Data.Property as Property
import qualified Data.Text as Text
import qualified GUI.Momentu as M
import qualified GUI.Momentu.Element as Element
import           GUI.Momentu.EventMap (EventMap)
import qualified GUI.Momentu.EventMap as E
import qualified GUI.Momentu.Glue as Glue
import qualified GUI.Momentu.Hover as Hover
import qualified GUI.Momentu.I18N as MomentuTexts
import qualified GUI.Momentu.MetaKey as MetaKey
import qualified GUI.Momentu.State as GuiState
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.Menu as Menu
import qualified GUI.Momentu.Widgets.Menu.Search as SearchMenu
import qualified GUI.Momentu.Widgets.Spacer as Spacer
import qualified GUI.Momentu.Widgets.TextView as TextView
import qualified Lamdu.Config as Config
import qualified Lamdu.Config.Theme as Theme
import           Lamdu.Config.Theme.TextColors (TextColors)
import qualified Lamdu.Config.Theme.TextColors as TextColors
import           Lamdu.Fuzzy (Fuzzy)
import qualified Lamdu.Fuzzy as Fuzzy
import           Lamdu.GUI.Monad (GuiM)
import qualified Lamdu.GUI.Monad as GuiM
import qualified Lamdu.GUI.NameView as NameView
import qualified Lamdu.GUI.Styled as Styled
import qualified Lamdu.GUI.TagView as TagView
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import qualified Lamdu.I18N.CodeUI as Texts
import qualified Lamdu.I18N.Navigation as Texts
import           Lamdu.Name (Name(..))
import qualified Lamdu.Name as Name
import qualified Lamdu.Style as Style
import           Lamdu.Sugar.EntityId (EntityId)
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

makePickEventMap :: _ => f Menu.PickResult -> m (EventMap (f M.Update))
makePickEventMap action =
    Lens.view id <&>
    \env ->
    let config = env ^. has . Config.menu
        pickKeys = config ^. Menu.keysPickOption
        jumpNextKeys = config ^. Menu.keysPickOptionAndGotoNext
        mkDoc lens =
            E.toDoc env [has . MomentuTexts.edit, has . Texts.tag, has . lens]
    in
    E.keysEventMapMovesCursor pickKeys (mkDoc Texts.new)
    (action <&> (^. Menu.pickDest))
    -- TODO: DRY with search-menu?
    <> E.keyPresses (jumpNextKeys <&> MetaKey.toModKey)
        (mkDoc Texts.newAndJumpToNextEntry)
        (action <&> \result ->
            case result ^. Menu.pickMNextEntry of
            Just nextEntry -> GuiState.updateCursor nextEntry
            Nothing ->
                GuiState.updateCursor (result ^. Menu.pickDest)
                & GuiState.uPreferStroll .~ True ^. Lens._Unwrapped
        )

makeNewTag ::
    (Monad i, Monad o) =>
    Sugar.TagOption Name o a ->
    GuiM env i o (Text -> (EntityId -> a -> b) -> o b)
makeNewTag tagOpt =
    GuiM.assocTagName <&>
    \assocTagName searchTerm mkPickResult ->
    do
        Property.setP (assocTagName (tagOpt ^. Sugar.toInfo . Sugar.tagVal)) searchTerm
        tagOpt ^. Sugar.toPick <&> mkPickResult (tagOpt ^. Sugar.toInfo . Sugar.tagInstance)

makeNewTagPreEvent ::
    _ =>
    Sugar.TagOption Name o a ->
    GuiM env i o (Text -> (EntityId -> a -> r) -> Maybe (Widget.PreEvent (o r)))
makeNewTagPreEvent tagOpt =
    (,) <$> Lens.view (has . Texts.newName) <*> makeNewTag tagOpt
    <&>
    \(newNameText, newTag) searchTerm mkPickResult ->
    if Text.null searchTerm
    then Nothing
    else
        Just Widget.PreEvent
        { Widget._pDesc = newNameText
        , Widget._pAction = newTag searchTerm mkPickResult
        , Widget._pTextRemainder = ""
        }

makeAddNewTag ::
    _ =>
    Sugar.TagOption Name o a ->
    GuiM menv i o
    ( (EntityId -> a -> Menu.PickResult) ->
        SearchMenu.ResultsContext -> Maybe (Menu.Option f o)
    )
makeAddNewTag tagOpt =
    makeNewTagPreEvent tagOpt <&>
    \newTagPreEvent mkPickResult ctx ->
    let optionId =
            (ctx ^. SearchMenu.rResultIdPrefix) `Widget.joinId` ["Create new"]
        searchTerm = ctx ^. SearchMenu.rSearchTerm
    in  newTagPreEvent searchTerm mkPickResult
        <&> \preEvent ->
        Menu.Option
        { Menu._oId = optionId
        , Menu._oSubmenuWidgets = Menu.SubmenuEmpty
        , Menu._oRender =
            (Widget.makeFocusableView ?? optionId <&> fmap)
            <*> Styled.label Texts.createNew
            <&> (`Menu.RenderedOption` preEvent)
            & Styled.withColor TextColors.actionTextColor
        }

nameText :: Lens.Traversal' (Sugar.TagOption Name m a) Text
nameText = Sugar.toInfo . Sugar.tagName . Name._NameTag . Name.tnDisplayText . Name.ttText

{-# NOINLINE fuzzyMaker #-}
fuzzyMaker :: [(Text, Int)] -> Fuzzy (Set Int)
fuzzyMaker = memo Fuzzy.make

makeOptions ::
    _ =>
    Sugar.TagChoice Name i o a ->
    Sugar.TagOption Name o a ->
    (EntityId -> a -> Menu.PickResult) ->
    SearchMenu.ResultsContext ->
    GuiM env i o (Menu.OptionList (Menu.Option m o))
makeOptions tagRefReplace newTagOpt mkPickResult ctx
    | Text.null searchTerm = pure Menu.TooMany
    | otherwise =
        do
            resultCount <-
                Lens.view
                (has . Config.completion . Config.completionResultCount)
            results <-
                tagRefReplace ^. Sugar.tcOptions
                <&> concatMap withText
                <&> (Fuzzy.memoableMake fuzzyMaker ?? searchTerm)
                & GuiM.im
            let nonFuzzyResults =
                    results ^? Lens.ix 0 . _1 . Fuzzy.isFuzzy
                    & any not
            addNewTag <- makeAddNewTag newTagOpt
            let maybeAddNewTagOption
                    | nonFuzzyResults || not (Name.isValidText searchTerm) = id
                    | otherwise =
                        maybe id (:) (addNewTag mkPickResult ctx)
            chooseText <- Lens.view (has . MomentuTexts.choose)
            let makeOption opt =
                    Menu.Option
                    { Menu._oId = optionWId
                    , Menu._oRender =
                        (Widget.makeFocusableView ?? optionWId <&> fmap)
                        <*> NameView.make (opt ^. Sugar.toInfo . Sugar.tagName)
                        & Reader.local (M.animIdPrefix .~ Widget.toAnimId instanceId)
                        <&>
                        \widget ->
                        Menu.RenderedOption
                        { Menu._rWidget = widget
                        , Menu._rPick = Widget.PreEvent
                            { Widget._pDesc = chooseText
                            , Widget._pAction =
                                opt ^. Sugar.toPick
                                <&> mkPickResult
                                (opt ^. Sugar.toInfo . Sugar.tagInstance)
                            , Widget._pTextRemainder = ""
                            }
                        }
                    , Menu._oSubmenuWidgets = Menu.SubmenuEmpty
                    }
                    where
                        instanceId =
                            opt ^. Sugar.toInfo . Sugar.tagInstance
                            & WidgetIds.fromEntityId
                        optionWId =
                            ctx ^. SearchMenu.rResultIdPrefix <> instanceId
            results <&> snd
                & splitAt resultCount
                & _2 %~ not . null
                & _1 %~ maybeAddNewTagOption . map makeOption
                & uncurry Menu.toOptionList
                & pure
    where
        withText tagOption = tagOption ^.. nameText <&> ((,) ?? tagOption)
        searchTerm = ctx ^. SearchMenu.rSearchTerm

allowedSearchTerm :: Text -> Bool
allowedSearchTerm = Name.isValidText

makeHoleSearchTerm ::
    _ =>
    Sugar.TagOption Name o a ->
    (EntityId -> a -> Menu.PickResult) -> Widget.Id ->
    GuiM env i o (SearchMenu.Term o)
makeHoleSearchTerm newTagOption mkPickResult holeId =
    do
        searchTerm <- SearchMenu.readSearchTerm holeId
        let allowNewTag = Name.isValidText searchTerm
        newTag <- makeNewTag newTagOption
        newTagEventMap <-
            if allowNewTag
            then newTag searchTerm mkPickResult & makePickEventMap
            else pure mempty
        newTagPreEvent <- makeNewTagPreEvent newTagOption
        let newTagPreEvents =
                newTagPreEvent searchTerm mkPickResult
                ^.. Lens._Just
                <&> fmap (mempty <$)
        let addPreEvents =
                Widget.wState . Widget._StateFocused . Lens.mapped .
                Widget.fPreEvents %~ (Widget.PreEvents newTagPreEvents <>)
        term <-
            SearchMenu.addDelSearchTerm holeId
            <*> SearchMenu.basicSearchTermEdit newTagId holeId (pure . allowedSearchTerm)
                SearchMenu.defaultEmptyStrings
            <&> SearchMenu.termWidget . M.tValue %~
                addPreEvents . Widget.weakerEvents newTagEventMap
        tooltip <- Lens.view (has . Theme.tooltip)
        if  allowNewTag &&
            Widget.isFocused (term ^. SearchMenu.termWidget . M.tValue)
            then
                do
                    newText <- Lens.view (has . Texts.new)
                    newTagLabel <-
                        (TextView.make ?? "(" <> newText <> ")")
                            <*> (Element.subAnimId ?? ["label"])
                    space <- Spacer.stdHSpace
                    hover <- Hover.hover
                    Glue.Poly (|||) <- Glue.mkPoly ?? Glue.Horizontal
                    anchor <- Hover.anchor <&> fmap
                    let hNewTagLabel = hover newTagLabel & Hover.sequenceHover
                    let termWithHover termW =
                            let hoverOptions =
                                    [ anchor (termW ||| space) ||| hNewTagLabel
                                    , hNewTagLabel ||| anchor (space ||| termW)
                                    ] <&> (^. M.tValue)
                            in  anchor termW
                                <&> Hover.hoverInPlaceOf hoverOptions
                    term & SearchMenu.termWidget %~ termWithHover & pure
                    & Reader.local (Hover.backgroundColor .~ tooltip ^. Theme.tooltipBgColor)
                    & Reader.local (TextView.color .~ tooltip ^. Theme.tooltipFgColor)
                    & Reader.local (M.animIdPrefix <>~ ["label"])
            else pure term
    where
        newTagId = newTagOption ^. Sugar.toInfo . Sugar.tagInstance & WidgetIds.fromEntityId & Widget.toAnimId

makeTagHoleEdit ::
    _ =>
    Sugar.TagChoice Name i o a ->
    (EntityId -> a -> Menu.PickResult) ->
    Widget.Id ->
    GuiM env i o (M.TextWidget o)
makeTagHoleEdit tagRefReplace mkPickResult holeId =
    do
        newTagOption <- tagRefReplace ^. Sugar.tcNewTag & GuiM.im
        SearchMenu.make
            (const (makeHoleSearchTerm newTagOption mkPickResult holeId))
            (makeOptions tagRefReplace newTagOption mkPickResult) M.empty holeId
            ?? Menu.AnyPlace

makeTagRefEdit :: _ => Sugar.TagRef Name i o -> GuiM env i o (M.TextWidget o)
makeTagRefEdit = makeTagRefEditWith id (const Nothing) <&> fmap snd

data TagRefEditType
    = TagHole
    | SimpleView
    deriving (Eq)

makeTagRefEditWith ::
    _ =>
    (n (M.TextWidget o) ->
     GuiM env i o (M.TextWidget o)) ->
    (Sugar.EntityId -> Maybe Widget.Id) ->
    Sugar.TagRef Name i o ->
    GuiM env i o (TagRefEditType, M.TextWidget o)
makeTagRefEditWith onView onPickNext tag =
    do
        isHole <- GuiState.isSubCursor ?? holeId
        env <- Lens.view id
        let jumpToTagEventMap jump =
                jump <&> WidgetIds.fromEntityId
                & E.keysEventMapMovesCursor
                (env ^. has . Config.jumpToDefinitionKeys)
                (E.toDoc env
                    [ has . MomentuTexts.edit
                    , has . Texts.tag
                    , has . Texts.jumpToTag
                    ])
        let chooseNewTagEventMap =
                E.keysEventMapMovesCursor
                (Config.delKeys env <> env ^. has . Config.jumpToDefinitionKeys)
                ( E.toDoc env
                    [ has . MomentuTexts.edit
                    , has . Texts.tag
                    , has . MomentuTexts.choose
                    ] ) chooseAction
        let eventMap =
                foldMap jumpToTagEventMap (tag ^. Sugar.tagRefJumpTo)
                <> chooseNewTagEventMap
        nameView <-
            (Widget.makeFocusableView ?? viewId <&> fmap) <*>
            TagView.make info
            <&> Lens.mapped %~ Widget.weakerEvents eventMap
            & onView
        let leaveHoleEventMap =
                E.keysEventMapMovesCursor
                (env ^. has . Config.completion . Config.completionCloseKeys)
                (E.toDoc env
                    [ has . MomentuTexts.navigation
                    , has . Texts.closeHole
                    ])
                (pure myId)
        if isHole
            then
                makeTagHoleEdit (tag ^. Sugar.tagRefReplace) mkPickResult holeId
                <&> M.tValue %~ Widget.weakerEvents leaveHoleEventMap
                <&> (,) TagHole
            else pure (SimpleView, nameView)
        & GuiState.assignCursor myId viewId
    where
        info = tag ^. Sugar.tagRefTag
        myId = info ^. Sugar.tagInstance & WidgetIds.fromEntityId
        holeId = WidgetIds.tagHoleId myId
        viewId = Widget.joinId myId ["view"]
        mkPickResult tagInstance () =
            Menu.PickResult
            { Menu._pickDest = WidgetIds.fromEntityId tagInstance
            , Menu._pickMNextEntry = onPickNext tagInstance
            }
        chooseAction =
            case tag ^. Sugar.tagRefReplace . Sugar.tcAnon of
            Nothing -> pure myId
            Just setAnon -> setAnon <&> fst <&> WidgetIds.fromEntityId
            <&> WidgetIds.tagHoleId

makeRecordTag :: _ => Sugar.TagRef Name i o -> GuiM env i o (M.TextWidget o)
makeRecordTag =
    makeTagRefEdit <&> Styled.withColor TextColors.recordTagColor

makeVariantTag :: _ => Sugar.TagRef Name i o -> GuiM env i o (M.TextWidget o)
makeVariantTag tag =
    makeTagRefEdit tag
    & Styled.withColor TextColors.caseTagColor

addParamId :: Widget.Id -> Widget.Id
addParamId = (`Widget.joinId` ["add param"])

makeLHSTag ::
    _ =>
    (Sugar.EntityId -> Maybe Widget.Id) ->
    Lens.ALens' TextColors M.Color -> Sugar.TagRef Name i o ->
    GuiM env i o (M.TextWidget o)
makeLHSTag onPickNext color tag =
    do
        env <- Lens.view id
        (tagEditType, tagEdit) <-
            makeTagRefEditWith onView onPickNext tag
            & Styled.withColor color
            & Reader.local (has .~ env ^. has . Style.nameAtBinder)
        let chooseEventMap =
                E.charEventMap "Letter"
                (E.toDoc env
                    [has . MomentuTexts.edit, has . Texts.tag, has . MomentuTexts.choose])
                chooseWithChar

        let eventMap =
                case tagEditType of
                SimpleView -> chooseEventMap
                _ -> mempty
        tagEdit <&> Widget.weakerEvents eventMap & pure
    where
        chooseWithChar c =
            SearchMenu.enterWithSearchTerm (Text.singleton c)
            (WidgetIds.tagHoleId myId)
            <$ guard (Char.isAlpha c)
            <&> pure
        myId = tag ^. Sugar.tagRefTag . Sugar.tagInstance & WidgetIds.fromEntityId
        -- Apply the name style only when the tag is a view. If it is
        -- a tag hole, the name style (indicating auto-name) makes no sense
        onView =
            Styled.nameAtBinder (tag ^. Sugar.tagRefTag . Sugar.tagName) .
            Styled.withColor color

makeParamTag :: _ => Sugar.TagRef Name i o -> GuiM env i o (M.TextWidget o)
makeParamTag =
    makeLHSTag onPickNext TextColors.parameterColor
    where
        onPickNext pos = WidgetIds.fromEntityId pos & addParamId & Just

-- | Unfocusable tag view (e.g: in apply args)
makeArgTag :: _ => Name -> Sugar.EntityId -> m (M.WithTextPos M.View)
makeArgTag name tagInstance =
    NameView.make name
    & Styled.withColor TextColors.argTagColor
    & Reader.local (M.animIdPrefix .~ animId)
    where
        animId = WidgetIds.fromEntityId tagInstance & Widget.toAnimId

makeBinderTagEdit ::
    _ =>
    Lens.ALens' TextColors M.Color -> Sugar.TagRef Name i o ->
    GuiM env i o (M.TextWidget o)
makeBinderTagEdit color tag =
    makeLHSTag (const Nothing) color tag
    & Reader.local (has . Menu.configKeys . Menu.keysPickOptionAndGotoNext .~ [])
