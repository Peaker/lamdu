module Lamdu.Sugar.Convert.Hole
    ( convert
    ) where

import qualified Control.Lens.Extended as Lens
import           Control.Monad.Transaction (MonadTransaction(..))
import           Data.Typeable (Typeable)
import           Hyper
import           Hyper.Recurse (wrap)
import           Hyper.Syntax (FuncType(..))
import           Hyper.Syntax.Row (freExtends, freRest)
import           Hyper.Type.Prune (Prune(..))
import qualified Lamdu.Builtins.Anchors as Builtins
import           Lamdu.Calc.Definition (depsNominals)
import qualified Lamdu.Calc.Term as V
import qualified Lamdu.Calc.Type as T
import qualified Lamdu.Data.Anchors as Anchors
import qualified Lamdu.Data.Ops as DataOps
import qualified Lamdu.Expr.IRef as ExprIRef
import qualified Lamdu.Expr.Load as Load
import qualified Lamdu.I18N.Code as Texts
import           Lamdu.Sugar.Convert.Expression.Actions (addActions)
import qualified Lamdu.Sugar.Convert.Input as Input
import           Lamdu.Sugar.Convert.Monad (ConvertM)
import qualified Lamdu.Sugar.Convert.Monad as ConvertM
import           Lamdu.Sugar.Convert.Option
import           Lamdu.Sugar.Internal
import           Lamdu.Sugar.Types
import qualified Revision.Deltum.Transaction as Transaction

import           Lamdu.Prelude

type T = Transaction.Transaction

convert ::
    (Monad m, Monoid a, Typeable m) =>
    ConvertM.PositionInfo ->
    Input.Payload m a # V.Term ->
    ConvertM m (ExpressionU EvalPrep m a)
convert posInfo holePl =
    do
        forType <- makeForType (holePl ^. Input.inferredType) & transaction
        let filtForType = filter (\x -> x ^. rExpr `notElem` (forType <&> (^. rExpr)))
        newTag <- DataOps.genNewTag & transaction
        tagsProp <- Lens.view Anchors.codeAnchors <&> Anchors.tags
        ResultGroups
            { gSyntax = makeResultsSyntax posInfo & transaction <&> filtForType
            , gDefs = makeGlobals makeGetDef
            , gLocals = makeLocals (const pure) (holePl ^. Input.inferScope)
            , gInjects =
                makeTagRes newTag "'" ((^. hPlain) . (`V.BAppP` V.BLeafP V.LRecEmpty) . V.BLeafP . V.LInject)
                <&> filtForType
            , gToNoms = makeNoms [] "" makeToNoms
            , gFromNoms =
                makeNoms [] "." (\_ x -> pure [simpleResult (_Pure . V._BLeaf . V._LFromNom # x) mempty])
                <&> filtForType
            , gForType = pure forType
            , gGetFields = makeTagRes newTag "." (Pure . V.BLeaf . V.LGetField)
            , gWrapInRecs = pure [] -- Only used in fragments
            }
            <&> (>>= traverse (makeOption holePl . fmap (\x -> [((), wrap (const (Ann ExprIRef.WriteNew)) x)])))
            & traverse ConvertM.convertOnce
            <&> filterResults tagsProp const
    -- The call to convertOnce makes the result expressions consistent.
    -- If we remove all calls to convertOnce (replacing with "fmap pure"),
    -- they would flicker when editing the search term.
    & ConvertM.convertOnce
    <&> BodyLeaf . LeafHole . Hole
    >>= addActions (Const ()) holePl
    <&> annotation . pActions . delete .~ CannotDelete
    <&> annotation . pActions . mApply .~ Nothing

makeToNoms :: Monad m => Pure # T.Type -> NominalId -> T m [Result (Pure # V.Term)]
makeToNoms t tid =
    case t ^. _Pure of
    -- Many nominals (like Maybe, List) wrap a sum type, suggest their various injections
    T.TVariant r | Lens.has (freRest . _Pure . T._REmpty) f ->
        f ^@.. freExtends . Lens.itraversed & traverse mkVariant
        where
            f = r ^. T.flatRow
            mkVariant (tag, typ) =
                simpleResult
                <$> (suggestVal typ <&> (_Pure . V._BApp #) . V.App (_Pure . V._BLeaf . V._LInject # tag))
                <*> (ExprIRef.readTagData tag <&> tagTexts <&> Lens.mapped %~ (>>= injTexts))
    _ -> suggestVal t <&> (:[]) . (simpleResult ?? mempty)
    <&> traverse . rExpr %~ Pure . V.BToNom . V.ToNom tid
    where
        -- "t" will be prefix for "Bool 'true" too,
        -- so that one doesn't have to type the "'" prefix
        injTexts x = [x, "'" <> x]

makeResultsSyntax :: Monad m => ConvertM.PositionInfo -> T m [Result (Pure # V.Term)]
makeResultsSyntax posInfo =
    sequenceA
    [ genLamVar <&> \v -> r lamTexts (V.BLamP v Pruned (V.BLeafP V.LHole))
    , r recTexts (V.BLeafP V.LRecEmpty) & pure
    , r caseTexts (V.BLeafP V.LAbsurd) & pure
    ] <>
    sequenceA
    [ genLamVar <&>
        \v ->
        r (^.. qCodeTexts . Texts.let_)
        (V.BLamP v Pruned (V.BLeafP V.LHole) `V.BAppP` V.BLeafP V.LHole)
    | posInfo == ConvertM.BinderPos
    ] <>
    do
        -- Suggest if-else only if bool is in the stdlib (otherwise tests fail)
        deps <-
            Load.nominal Builtins.boolTid
            <&> \(Right x) -> mempty & depsNominals . Lens.at Builtins.boolTid ?~ x
        if Lens.has (depsNominals . Lens.ix Builtins.boolTid) deps then
            do
                t <- genLamVar
                f <- genLamVar
                pure [Result
                    { _rTexts = QueryTexts ifTexts
                    , _rAllowEmptyQuery = False
                    , _rExpr =
                        ( V.BLeafP V.LAbsurd
                        & V.BCaseP Builtins.falseTag (V.BLamP f Pruned (V.BLeafP V.LHole))
                        & V.BCaseP Builtins.trueTag (V.BLamP t Pruned (V.BLeafP V.LHole))
                        ) `V.BAppP`
                        (V.BLeafP (V.LFromNom Builtins.boolTid) `V.BAppP` V.BLeafP V.LHole)
                        ^. hPlain
                    , _rDeps = deps
                    }]
            else pure []
    where
        r f t = simpleResult (t ^. hPlain) f

makeGetDef :: Monad m => V.Var -> Pure # T.Type -> T m (Maybe (Pure # V.Term))
makeGetDef v t =
    case t of
    Pure (T.TFun (FuncType a _))
        -- Avoid filling in params for open records
        | Lens.nullOf (_Pure . T._TRecord . T.flatRow . freRest . _Pure . T._RVar) a ->
            suggestVal a <&> Pure . V.BApp . V.App base
    _ -> pure base
    <&> Just
    where
        base = _Pure . V._BLeaf . V._LVar # v
