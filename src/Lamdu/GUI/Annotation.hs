{-# LANGUAGE TypeFamilies, TupleSections #-}

module Lamdu.GUI.Annotation
    ( annotationSpacer
    , NeighborVals(..)
    , EvalAnnotationOptions(..), maybeAddAnnotationWith

    , addInferredType, shrinkValAnnotationsIfNeeded

    , PostProcessAnnotation, WhichAnnotation(..), ShrinkRatio
    , postProcessAnnotationFromSelected

    , addAnnotationBackground -- used for open holes
    , maybeAddAnnotationPl
    ) where

import qualified Control.Lens as Lens
import qualified Control.Monad.Reader as Reader
import           Data.CurAndPrev (CurAndPrev(..), CurPrevTag(..), curPrevTag, fallbackToPrev)
import qualified GUI.Momentu as M
import qualified GUI.Momentu.Align as Align
import qualified GUI.Momentu.Draw as Draw
import qualified GUI.Momentu.Element as Element
import qualified GUI.Momentu.Glue as Glue
import qualified GUI.Momentu.State as GuiState
import qualified GUI.Momentu.View as View
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.Spacer as Spacer
import qualified Lamdu.Config.Theme as Theme
import           Lamdu.Config.Theme.ValAnnotation (ValAnnotation)
import qualified Lamdu.Config.Theme.ValAnnotation as ValAnnotation
import qualified Lamdu.GUI.EvalView as EvalView
import           Lamdu.GUI.Monad (GuiM)
import qualified Lamdu.GUI.Monad as GuiM
import qualified Lamdu.GUI.Styled as Styled
import qualified Lamdu.GUI.TypeView as TypeView
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.Name (Name)
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

addAnnotationBackgroundH :: _ => Lens.ALens' ValAnnotation Draw.Color -> m (a -> a)
addAnnotationBackgroundH color =
    do
        t <- Lens.view has
        bgAnimId <- Element.subAnimId ?? ["annotation background"]
        Draw.backgroundColor bgAnimId (t ^# Theme.valAnnotation . color) & pure

addAnnotationBackground :: _ => m (a -> a)
addAnnotationBackground = addAnnotationBackgroundH ValAnnotation.valAnnotationBGColor

addAnnotationHoverBackground :: _ => m (a -> a)
addAnnotationHoverBackground = addAnnotationBackgroundH ValAnnotation.valAnnotationHoverBGColor

data WhichAnnotation = TypeAnnotation | ValAnnotation

type ShrinkRatio = M.Vector2 Widget.R

type PostProcessAnnotation m = WhichAnnotation -> m (ShrinkRatio -> M.View -> M.View)

postProcessAnnotationFromSelected :: _ => Bool -> PostProcessAnnotation m
postProcessAnnotationFromSelected False = shrinkIfNeeded
postProcessAnnotationFromSelected True = hoverWideAnnotation

shrinkValAnnotationsIfNeeded :: _ => PostProcessAnnotation m
shrinkValAnnotationsIfNeeded TypeAnnotation = addAnnotationBackground <&> const
shrinkValAnnotationsIfNeeded ValAnnotation = shrinkIfNeeded ValAnnotation

shrinkIfNeeded :: _ => PostProcessAnnotation m
shrinkIfNeeded _ =
    addAnnotationBackground
    <&>
    \addBg shrinkRatio view ->
    M.scale shrinkRatio view & addBg

hoverWideAnnotation :: _ => PostProcessAnnotation m
hoverWideAnnotation which =
    do
        shrinker <- shrinkIfNeeded which
        addBg <- addAnnotationHoverBackground
        pad <- Element.pad
        pure $
            \shrinkRatio wideView ->
                let shrunkView = shrinker shrinkRatio wideView
                -- TODO: This is a buggy hover that ignores
                -- Surrounding (and exits screen).
                in
                addBg wideView
                & pad 0 (shrunkView ^. View.vSize - wideView ^. View.vSize)
                & Element.hoverLayeredImage

processAnnotationGui :: _ => m (ShrinkRatio -> M.View -> M.View) -> m (Widget.R -> M.View -> M.View)
processAnnotationGui postProcessAnnotation =
    f
    <$> Lens.view (has . Theme.valAnnotation)
    <*> Spacer.getSpaceSize
    <*> postProcessAnnotation
    where
        f th stdSpacing postProcess minWidth ann
            | annWidth > minWidth + max shrinkAtLeast expansionLimit
            || heightShrinkRatio < 1 =
                postProcess shrinkRatio ann
            | otherwise =
                maybeTooNarrow ann & postProcess 1.0
            where
                annWidth = ann ^. M.width
                expansionLimit = th ^. ValAnnotation.valAnnotationWidthExpansionLimit
                maxWidth = minWidth + expansionLimit
                shrinkAtLeast = th ^. ValAnnotation.valAnnotationShrinkAtLeast
                heightShrinkRatio =
                    th ^. ValAnnotation.valAnnotationMaxHeight * stdSpacing ^. _2
                    / ann ^. M.height
                shrinkRatio =
                    annWidth - shrinkAtLeast & min maxWidth & max minWidth
                    & (/ annWidth) & min heightShrinkRatio & pure
                maybeTooNarrow
                    | minWidth > annWidth =
                        M.padAround (M.Vector2 ((minWidth - annWidth) / 2) 0)
                    | otherwise = id

data EvalResDisplay name = EvalResDisplay
    { erdSource :: CurPrevTag
    , erdVal :: Sugar.ResVal name
    }

makeEvaluationResultView :: _ => EvalResDisplay Name -> GuiM env i o (M.WithTextPos M.View)
makeEvaluationResultView res =
    do
        th <- Lens.view has
        EvalView.make (erdVal res)
            <&>
            case erdSource res of
            Current -> id
            Prev -> M.tint (th ^. Theme.eval . Theme.staleResultTint)

data NeighborVals a = NeighborVals
    { prevNeighbor :: a
    , nextNeighbor :: a
    } deriving (Functor, Foldable, Traversable)

makeEvalView ::
    _ =>
    Maybe (NeighborVals (Maybe (EvalResDisplay Name))) ->
    EvalResDisplay Name -> GuiM env i o (M.WithTextPos M.View)
makeEvalView mNeighbours evalRes =
    do
        evalTheme <- Lens.view (has . Theme.eval)
        let neighbourView n =
                Lens._Just makeEvaluationResultViewBG n
                <&> Lens.mapped %~ M.scale (evalTheme ^. Theme.neighborsScaleFactor)
                <&> Lens.mapped %~ M.padAround (evalTheme ^. Theme.neighborsPadding)
                <&> fromMaybe M.empty
        (prev, next) <-
            case mNeighbours of
            Nothing -> pure (M.empty, M.empty)
            Just (NeighborVals mPrev mNext) ->
                (,)
                <$> neighbourView mPrev
                <*> neighbourView mNext
        evalView <- makeEvaluationResultView evalRes
        let prevPos = M.Vector2 0 0.5 * evalView ^. Element.size - prev ^. Element.size
        let nextPos = M.Vector2 1 0.5 * evalView ^. Element.size
        evalView
            & Element.setLayeredImage <>~ Element.translateLayeredImage prevPos (prev ^. View.vAnimLayers)
            & Element.setLayeredImage <>~ Element.translateLayeredImage nextPos (next ^. View.vAnimLayers)
            & pure
    where
        evalAnimId erd =
            erdVal erd ^. Sugar.resPayload & WidgetIds.fromEntityId & Widget.toAnimId
        makeEvaluationResultViewBG res =
            ( addAnnotationBackground
            & Reader.local (M.animIdPrefix .~ evalAnimId res)
            ) <*> makeEvaluationResultView res
            <&> (^. Align.tValue)

annotationSpacer :: _ => m M.View
annotationSpacer =
    Lens.view (has . Theme.valAnnotation . ValAnnotation.valAnnotationSpacing)
    >>= Spacer.vspaceLines

addAnnotationH ::
    _ => m (M.WithTextPos M.View) -> m (ShrinkRatio -> M.View -> M.View) -> m (M.Widget f -> M.Widget f)
addAnnotationH f postProcess =
    do
        vspace <- annotationSpacer
        annotationLayout <- f <&> (^. Align.tValue)
        processAnn <- processAnnotationGui postProcess
        padToSize <- Element.padToSize
        let ann w =
                processAnn (w ^. M.width) annotationLayout
                & padToSize (M.Vector2 theMinWidth 0) 0
                where
                    theMinWidth = w ^. M.width
        (|---|) <- Glue.mkGlue ?? Glue.Vertical
        pure (\w -> w |---| vspace |---| ann w)

addInferredType ::
    _ =>
    Annotated Sugar.EntityId # Sugar.Type Name -> PostProcessAnnotation m ->
    m (M.Widget f -> M.Widget f)
addInferredType typ postProcess =
    addAnnotationH (TypeView.make typ) (postProcess TypeAnnotation)

addEvaluationResult ::
    _ =>
    Maybe (NeighborVals (Maybe (EvalResDisplay Name))) ->
    EvalResDisplay Name -> PostProcessAnnotation (GuiM env i o) ->
    GuiM env i o (M.Widget f -> M.Widget f)
addEvaluationResult mNeigh resDisp postProcess =
    case erdVal resDisp ^. Sugar.resBody of
    Sugar.RRecord (Sugar.ResRecord []) -> Styled.addBgColor Theme.evaluatedPathBGColor
    Sugar.RFunc _ -> pure id
    _ -> addAnnotationH (makeEvalView mNeigh resDisp) (postProcess ValAnnotation)

maybeAddAnnotationPl ::
    _ =>
    Sugar.Payload (Sugar.Annotation (Sugar.EvaluationScopes Name i) Name) Name i o1 ->
    GuiM env i o (M.Widget o -> M.Widget o)
maybeAddAnnotationPl pl =
    do
        postProcessAnnotation <-
            if pl ^. Sugar.plNeverShrinkTypeAnnotations
            then pure shrinkValAnnotationsIfNeeded
            else isExprSelected <&> postProcessAnnotationFromSelected
        maybeAddAnnotation postProcessAnnotation
            (pl ^. Sugar.plAnnotation)
            & Reader.local (M.animIdPrefix .~ animId)
    where
        isExprSelected = GuiState.isSubCursor ?? WidgetIds.fromExprPayload pl
        animId = WidgetIds.fromExprPayload pl & Widget.toAnimId

data EvalAnnotationOptions
    = NormalEvalAnnotation
    | WithNeighbouringEvalAnnotations (NeighborVals (Maybe Sugar.BinderParamScopeId))

getAnnotationMode ::
    Monad i =>
    EvalAnnotationOptions -> Sugar.EvaluationScopes name i ->
    GuiM env i o (Maybe (EvalResDisplay name, Maybe (NeighborVals (Maybe (EvalResDisplay name)))))
getAnnotationMode opt ann =
    do
        neighbourVals <-
            case opt of
            NormalEvalAnnotation -> pure Nothing
            WithNeighbouringEvalAnnotations neighbors ->
                -- neighbors <&> (>>= valOfScopePreferCur ann . (^. Sugar.bParamScopeId))
                -- & Just
                neighbors & traverse . Lens._Just %%~
                    GuiM.im . valOfScopePreferCur ann . (^. Sugar.bParamScopeId)
                <&> traverse %~ join
                <&> Just
        GuiM.readMScopeId
            >>= GuiM.im . valOfScope ann
            <&> Lens.mapped %~ (, neighbourVals)

maybeAddAnnotationWith ::
    _ =>
    EvalAnnotationOptions -> PostProcessAnnotation (GuiM env i o) ->
    Sugar.Annotation (Sugar.EvaluationScopes Name i) Name ->
    GuiM env i o (M.Widget o -> M.Widget o)
maybeAddAnnotationWith opt postProcessAnnotation ann =
    case ann of
    Sugar.AnnotationNone -> pure id
    Sugar.AnnotationType typ -> addInferredType typ postProcessAnnotation
    Sugar.AnnotationVal val -> maybeAddValAnnotationWith opt postProcessAnnotation val

maybeAddValAnnotationWith ::
    _ =>
    EvalAnnotationOptions -> PostProcessAnnotation (GuiM env i o) ->
    Sugar.EvaluationScopes Name i ->
    GuiM env i o (M.Widget o -> M.Widget o)
maybeAddValAnnotationWith opt postProcessAnnotation ann =
    getAnnotationMode opt ann
    >>=
    \case
    Nothing -> pure id
    Just (scopeAndVal, mNeighborVals) ->
        addEvaluationResult mNeighborVals scopeAndVal postProcessAnnotation

maybeAddAnnotation ::
    _ =>
    PostProcessAnnotation (GuiM env i o) ->
    Sugar.Annotation (Sugar.EvaluationScopes Name i) Name ->
    GuiM env i o (M.Widget o -> M.Widget o)
maybeAddAnnotation = maybeAddAnnotationWith NormalEvalAnnotation

valOfScope ::
    Applicative i =>
    Sugar.EvaluationScopes name i -> CurAndPrev (Maybe Sugar.ScopeId) ->
    i (Maybe (EvalResDisplay name))
valOfScope curPrevAnn mScopeIds =
    go
    <$> curPrevTag
    <*> curPrevAnn
    <*> mScopeIds
    & fallbackToPrev
    & sequenceA
    where
        go _ _ Nothing = Nothing
        go tag ann (Just scopeId) =
            ann ^? Lens._Just . Lens.ix scopeId <&> Lens.mapped %~ EvalResDisplay tag

valOfScopePreferCur ::
    Applicative i =>
    Sugar.EvaluationScopes name i -> Sugar.ScopeId ->
    i (Maybe (EvalResDisplay name))
valOfScopePreferCur ann = valOfScope ann . pure . Just
