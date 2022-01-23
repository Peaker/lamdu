{-# LANGUAGE PolyKinds #-}

module Lamdu.Sugar.Convert.GetVar
    ( convert
    ) where

import qualified Control.Lens as Lens
import           Control.Lens.Extended ((~~>))
import           Control.Monad.Trans.Except.Extended (runMatcherT, justToLeft)
import           Control.Monad.Trans.Maybe (MaybeT)
import           Control.Monad.Transaction (MonadTransaction, getP, setP)
import qualified Control.Monad.Transaction as Transaction
import           Data.Maybe.Extended (maybeToMPlus)
import qualified Data.Property as Property
import qualified Data.Set as Set
import           Hyper
import qualified Hyper.Syntax.Scheme as S
import qualified Lamdu.Calc.Lens as ExprLens
import qualified Lamdu.Calc.Term as V
import qualified Lamdu.Calc.Type as T
import qualified Lamdu.Data.Anchors as Anchors
import qualified Lamdu.Data.Definition as Def
import qualified Lamdu.Data.Ops as DataOps
import           Lamdu.Expr.IRef (HRef)
import qualified Lamdu.Expr.IRef as ExprIRef
import           Lamdu.Sugar.Convert.Binder.Params (mkVarInfo)
import           Lamdu.Sugar.Convert.Expression.Actions (addActions)
import qualified Lamdu.Sugar.Convert.Input as Input
import           Lamdu.Sugar.Convert.Monad (ConvertM)
import qualified Lamdu.Sugar.Convert.Monad as ConvertM
import qualified Lamdu.Sugar.Convert.NameRef as NameRef
import           Lamdu.Sugar.Internal
import qualified Lamdu.Sugar.Internal.EntityId as EntityId
import           Lamdu.Sugar.Types
import           Revision.Deltum.Transaction (Transaction)

import           Lamdu.Prelude

type T = Transaction

inlineDef :: Monad m => V.Var -> HRef m # V.Term -> ConvertM m (T m EntityId)
inlineDef globalId dest =
    (,)
    <$> Lens.view id
    <*> ConvertM.postProcessAssert
    <&>
    \(ctx, postProcess) ->
    do
        let gotoDef = NameRef.jumpToDefinition (ctx ^. Anchors.codeAnchors) defI
        let doInline def defExpr =
                do
                    (dest ^. ExprIRef.setIref) (defExpr ^. Def.expr)
                    Property.pureModify (ctx ^. ConvertM.scFrozenDeps) (<> defExpr ^. Def.exprFrozenDeps)
                    newDefExpr <- DataOps.newHole
                    def & Def.defBody .~ Def.BodyExpr (Def.Expr newDefExpr mempty)
                        & Def.defType .~
                            _Pure # S.Scheme
                            { S._sForAlls = T.Types (S.QVars ("a" ~~> mempty)) (S.QVars mempty)
                            , S._sTyp = _Pure # T.TVar "a"
                            }
                        & Transaction.writeIRef defI
                    setP (Anchors.assocDefinitionState defI) DeletedDefinition
                    postProcess
                    defExpr ^. Def.expr & EntityId.ofValI & pure
        def <- Transaction.readIRef defI
        case def ^. Def.defBody of
            Def.BodyBuiltin _ ->
                -- Cannot inline builtins.
                -- Jump to it instead so that user understands that it's a builtin.
                gotoDef
            Def.BodyExpr defExpr ->
                do
                    isRecursive <-
                        ExprIRef.readRecursively (defExpr ^. Def.expr)
                        <&> Lens.has (ExprLens.valGlobals mempty . Lens.only globalId)
                    if isRecursive
                        then gotoDef
                        else doInline def defExpr
    where
        defI = ExprIRef.defI globalId

inlineableDefinition :: ConvertM.Context m -> V.Var -> EntityId -> Bool
inlineableDefinition ctx var entityId =
    Lens.nullOf
    (ConvertM.scTopLevelExpr . ExprLens.valGlobals recursiveVars . Lens.ifiltered f)
    ctx
    where
        recursiveVars =
            ctx ^.
            ConvertM.scScopeInfo . ConvertM.siRecursiveRef . Lens._Just . ConvertM.rrDefI .
            Lens.to (Set.singleton . ExprIRef.globalId)
        f pl v = v == var && entityId /= pl ^. Input.entityId

convertGlobal ::
    Monad m =>
    V.Var -> Input.Payload m # V.Term -> MaybeT (ConvertM m) (GetVar InternalName (T m))
convertGlobal var exprPl =
    do
        ctx <- Lens.view id
        notElem var (exprPl ^. Input.localsInScope <&> fst) & guard
        lifeState <- Anchors.assocDefinitionState defI & getP
        let defForm =
                case lifeState of
                DeletedDefinition -> DefDeleted
                LiveDefinition ->
                    ctx ^. ConvertM.scOutdatedDefinitions . Lens.at var
                    <&> Lens.mapped .~ exprPl ^. Input.entityId
                    & maybe DefUpToDate DefTypeChanged
        nameRef <- NameRef.makeForDefinition (ctx ^. Anchors.codeAnchors) defI & lift
        inline <-
            case defForm of
            DefUpToDate
                | inlineableDefinition ctx var (exprPl ^. Input.entityId) ->
                    inlineDef var (exprPl ^. Input.stored) & lift <&> InlineVar
            _ -> pure CannotInline
        pure GetVar
            { _vNameRef = nameRef
            , _vVar = var
            , _vForm = GetDefinition defForm
            , _vInline = inline
            }
    where
        defI = ExprIRef.defI var

convertGetLet ::
    Monad m =>
    V.Var -> Input.Payload m # V.Term -> MaybeT (ConvertM m) (GetVar InternalName (T m))
convertGetLet param exprPl =
    do
        inline <-
            Lens.view (ConvertM.scScopeInfo . ConvertM.siLetItems . Lens.at param)
            >>= maybeToMPlus
        varInfo <- mkVarInfo (exprPl ^. Input.inferredType)
        nameRef <- convertLocalNameRef varInfo param
        pure GetVar
            { _vNameRef = nameRef
            , _vVar = param
            , _vForm = GetNormalVar
            , _vInline = inline (exprPl ^. Input.entityId)
            }

convertLocalNameRef ::
    (Applicative f, MonadTransaction n m) =>
    VarInfo -> V.Var -> m (NameRef InternalName f)
convertLocalNameRef varInfo param =
    Anchors.assocTag param & getP
    <&> \tag ->
    NameRef
    { _nrName = nameWithContext (Just varInfo) param tag
    , _nrGotoDefinition = EntityId.ofTaggedEntity param tag & pure
    }

convertParam ::
    (MonadTransaction u m, Applicative n) =>
    V.Var -> Input.Payload u # V.Term -> m (GetVar InternalName n)
convertParam param exprPl =
    mkVarInfo (exprPl ^. Input.inferredType)
    >>= (`convertLocalNameRef` param)
    <&>
    \nameRef ->
    GetVar
    { _vNameRef = nameRef
    , _vForm = GetNormalVar
    , _vInline = CannotInline -- TODO: In some cases can inline param
    , _vVar = param
    }

convert :: Monad m => V.Var -> Input.Payload m # V.Term -> ConvertM m (ExpressionU v m)
convert param exprPl =
    do
        convertGlobal param exprPl & justToLeft
        convertGetLet param exprPl & justToLeft
        convertParam param exprPl & lift
    & runMatcherT
    <&> BodyLeaf . LeafGetVar
    >>= addActions (Ann exprPl (V.BLeaf (V.LVar param)))
