-- | Convert applied holes to Fragments

module Lamdu.Sugar.Convert.Fragment
    ( convertAppliedHole
    ) where

import qualified Control.Lens as Lens
import           Control.Monad.Trans.Maybe (MaybeT(..))
import           Control.Monad.Transaction (MonadTransaction(..))
import qualified Data.Char as Char
import           Data.Property (getP)
import qualified Data.Map as Map
import           Data.Typeable (Typeable)
import           Generic.Data (gconIndex)
import           Hyper
import           Hyper.Class.Context
import           Hyper.Recurse
import           Hyper.Syntax (FuncType(..), funcIn)
import           Hyper.Syntax.Nominal (nId, nScheme)
import           Hyper.Syntax.Row (FlatRowExtends, freExtends)
import           Hyper.Syntax.Scheme (sTyp)
import           Hyper.Type.Prune (Prune(..))
import           Hyper.Unify (UVar, applyBindings, unify)
import           Lamdu.Calc.Definition (depsNominals)
import qualified Lamdu.Calc.Infer as Infer
import qualified Lamdu.Calc.Lens as ExprLens
import qualified Lamdu.Calc.Term as V
import qualified Lamdu.Calc.Type as T
import qualified Lamdu.Builtins.Anchors as Builtins
import qualified Lamdu.Data.Anchors as Anchors
import qualified Lamdu.Data.Ops as DataOps
import           Lamdu.Data.Tag (tagOrder)
import           Lamdu.Expr.IRef (iref)
import qualified Lamdu.Expr.IRef as ExprIRef
import qualified Lamdu.Expr.Load as Load
import qualified Lamdu.Sugar.Config as Config
import           Lamdu.Sugar.Convert.Annotation (makeTypeAnnotation)
import qualified Lamdu.Sugar.Convert.Expression.Actions as Actions
import qualified Lamdu.Sugar.Convert.Hole as Hole
import           Lamdu.Sugar.Convert.Fragment.Heal (healMismatch)
import qualified Lamdu.Sugar.Convert.Input as Input
import           Lamdu.Sugar.Convert.Monad (ConvertM)
import qualified Lamdu.Sugar.Convert.Monad as ConvertM
import           Lamdu.Sugar.Convert.Option
import           Lamdu.Sugar.Internal
import qualified Lamdu.Sugar.Internal.EntityId as EntityId
import           Lamdu.Sugar.Types
import           Revision.Deltum.Hyper (Write(..))
import qualified Revision.Deltum.Transaction as Transaction

import           Lamdu.Prelude

type T = Transaction.Transaction

checkTypeMatch :: Monad m => UVar # T.Type -> UVar # T.Type -> ConvertM m Bool
checkTypeMatch x y =
    Lens.view ConvertM.scInferContext <&> check <&> Lens.has Lens._Right
    where
        check ctx = unify x y >> applyBindings x & Infer.runPureInfer () ctx

convertAppliedHole ::
    (Monad m, Typeable m) =>
    Ann (Input.Payload m) # V.Term ->
    Input.Payload m # V.Term ->
    ExpressionU EvalPrep m ->
    MaybeT (ConvertM m) (ExpressionU EvalPrep m)
convertAppliedHole funcI exprPl argS =
    do
        Lens.view (ConvertM.scConfig . Config.sugarsEnabled . Config.fragment) >>= guard
        guard (Lens.has ExprLens.valHole funcI)
        do
            isTypeMatch <-
                checkTypeMatch (argI ^. hAnn . Input.inferredTypeUVar)
                (exprPl ^. Input.inferredTypeUVar)
            postProcess <- ConvertM.postProcessAssert
            healMis <- healMismatch
            typeMismatch <-
                if isTypeMatch
                then pure Nothing
                else
                    makeTypeAnnotation
                        (EntityId.ofFragmentArg (argS ^. annotation . pEntityId))
                        (argS ^. annotation . pUnsugared . hAnn . Input.inferredType) <&> Just
            tagsProp <- Lens.view Anchors.codeAnchors <&> Anchors.tags
            opts <-
                do
                    forType <- transformArg exprPl argI & transaction
                    newTag <- DataOps.genNewTag & transaction
                    ResultGroups
                        { gDefs =
                            makeGlobals (makeGetDef topRef argI)
                            <&> traverse . rTexts . _QueryTexts . Lens.mapped . Lens.mapped . traverse %~ toOpName
                        , gLocals =
                            makeLocals (makeLocal topRef argI) (exprPl ^. Input.inferScope)
                            <&> traverse %~ sequenceA <&> (^.. traverse . Lens._Just)
                        , gInjects = makeTagRes newTag "'" (Pure . V.BLeaf . V.LInject) <&> funcOpt
                        , gToNoms = makeNoms [] "" (makeToNom argI <&> Lens.mapped . Lens.mapped %~ (:[]) . (simpleResult ?? mempty))
                        , gFromNoms =
                            makeNoms (forType ^.. Lens.folded . _1 . Lens._Just)
                            "." (makeFromNom exprPl argI <&> Lens.mapped . Lens.mapped %~ (:[]))
                        , gForType = forType ^.. Lens.folded . _2 & pure
                        , gGetFields = makeTagRes newTag "." (Pure . V.BLeaf . V.LGetField) <&> funcOpt
                        , gSyntax = makeResultsSyntax exprPl argI & transaction
                        , gWrapInRecs =
                            makeTagRes newTag "{"
                            (\t ->
                                [ (TypeMatches
                                    , V.RowExtend t
                                        (argI & hflipped %~ hmap (const (ExistingRef . (^. Input.stored . ExprIRef.iref))))
                                        (Ann WriteNew (V.BLeaf V.LRecEmpty))
                                        & V.BRecExtend & Ann WriteNew
                                    )
                                ]
                            )
                        } <&> (>>= traverse (makeOption exprPl))
                        <&> Lens.mapped . traverse . rExpr . _2 . optionExpr %~ toFragOpt
                        & traverse ConvertM.convertOnce
                & ConvertM.convertOnce
            argOpts <-
                case argI ^? hAnn . Input.inferredType . _Pure . T._TFun . funcIn of
                Just t | Lens.nullOf (hVal . V._BLam) argI ->
                    Hole.results ConvertM.ExpressionPos t (exprPl ^. Input.inferScope)
                    <&> Lens.mapped %~
                        (Lens.mapped . traverse . rExpr . _2 %~ toArg) .
                        (>>= traverse (makeOption exprPl . fmap (applyArg argI)))
                    >>= traverse ConvertM.convertOnce
                    & ConvertM.convertOnce
                _ -> pure mempty
            apply <-
                argI ^. hAnn . Input.stored
                & ExprIRef.setIref .~ exprPl ^. Input.stored . ExprIRef.setIref
                & Actions.makeApply
            optApply <-
                makeOption exprPl
                Result
                { _rExpr = _Pure # V.BLeaf V.LHole & applyArg argI
                , _rDeps = mempty
                , _rTexts = QueryTexts mempty
                , _rWithTypeAnnotations = False
                , _rAllowEmptyQuery = True
                }
                <&> toArg . (^. rExpr . _2)
                & ConvertM.convertOnce
            BodyFragment Fragment
                { _fExpr =
                    argS
                    & annotation . pActions . detach .~ FragmentedAlready storedEntityId
                    & annotation . pActions . delete .~
                        SetToHole
                        (DataOps.setToHole stored <* postProcess <&> EntityId.ofValI)
                    & annotation . pActions . mApply ?~ apply
                , _fHeal =
                    ( if isTypeMatch
                        then DataOps.replace stored argIRef <* postProcess
                        else argIRef <$ healMis (stored ^. iref)
                    )
                    <&> EntityId.ofValI
                , _fTypeMismatch = typeMismatch
                , _fOptions = opts <> argOpts <&> filterResults tagsProp (\outerMatch innerMatch -> (innerMatch, outerMatch))
                , _fOptApply = optApply
                , _fTagSuffixes = mempty
                } & pure
            >>= Actions.addActions (Ann exprPl (V.BApp (App funcI argI)))
            & lift
        <&> annotation . pActions . detach .~ FragmentedAlready storedEntityId
    where
        argI = argS ^. annotation . pUnsugared
        toArg = optionExpr . annValue %~ FragArgument
        topRef = exprPl ^. Input.stored . ExprIRef.iref
        funcOpt = traverse . rExpr %~ makeFuncOpts
        argIRef = argI ^. hAnn . Input.stored . iref
        stored = exprPl ^. Input.stored
        storedEntityId = stored ^. iref & EntityId.ofValI
        makeFuncOpts opt = emplaceArg argI <&> _2 %~ Ann (ExistingRef topRef) . V.BApp . App (writeNew opt)

applyArg :: Ann (Input.Payload m) # V.Term -> Pure # V.Term -> [(TypeMatch, Ann (Write m) # V.Term)]
applyArg argI x =
    emplaceArg argI
    <&> _2 %~ Ann ExprIRef.WriteNew . V.BApp . (`V.App` wrap (const (Ann ExprIRef.WriteNew)) x)

makeResultsSyntax ::
    Monad m =>
    Input.Payload m # V.Term -> Ann (Input.Payload m) # V.Term ->
    T m [Result [(TypeMatch, Ann (Write m) # V.Term)]]
makeResultsSyntax top arg =
    sequenceA
    [ genLamVar <&>
        \v ->
        simpleResult
        (emplaceArg arg <&> _2 %~ Ann WriteNew . V.BLam . V.TypedLam v (Ann WriteNew (HCompose Pruned)))
        (const (lamTexts (top ^. Input.inferredType)))
    , simpleResult
        (emplaceArg arg <&> _2 %~
            Ann (ExistingRef (top ^. Input.stored . ExprIRef.iref)) .
            V.BApp . V.App (Ann WriteNew (V.BLeaf V.LAbsurd)))
            (const caseTexts)
        & pure
    ]

writeNew :: Pure # V.Term -> Ann (Write m) # V.Term
writeNew = wrap (const (Ann WriteNew))

transformArg ::
    Monad m =>
    Input.Payload m # V.Term -> Ann (Input.Payload m) # V.Term ->
    T m [(Maybe T.NominalId, Result [(TypeMatch, Ann (Write m) # V.Term)])]
transformArg topPl arg =
    case arg ^? hAnn . Input.inferredType . _Pure . T._TInst . nId of
    Just tid ->
        Load.nominal tid
        >>=
        \case
        Left _params -> replaceFunc
        Right s ->
            s ^.. _Pure . nScheme . sTyp . _Pure . T._TVariant
            & Lens.traverse %%~
            \r ->
            simpleResult
            <$> ( suggestCase r topType <&>
                    \c ->
                    emplaceArg arg
                    <&> _2 %~
                        Ann WriteNew . V.BApp . App (writeNew c) .
                        Ann WriteNew . V.BApp . App (Ann WriteNew (V.BLeaf (V.LFromNom tid)))
                )
            <*> (symTexts "." tid <&> (<> const (fromNomTexts tid)))
            <&> rDeps . depsNominals . Lens.at tid ?~ s
        <&> Lens.mapped %~ (,) (Just tid)
    Nothing -> replaceFunc <&> Lens.mapped %~ (,) Nothing
    where
        topType = topPl ^. Input.inferredType
        replaceFunc =
            makeForType (_Pure . T._TFun # FuncType (arg ^. hAnn . Input.inferredType) topType)
            <&> Lens.mapped . rExpr %~
            \f ->
            emplaceArg arg
            <&> _2 %~ Ann (ExistingRef (topPl ^. Input.stored . ExprIRef.iref)) . V.BApp . App (writeNew f)

makeLocal ::
    Monad m =>
    ExprIRef.ValI m -> Ann (Input.Payload m) # V.Term ->
    Pure # T.Type -> Pure # V.Term -> T m (Maybe [(TypeMatch, Ann (Write m) # V.Term)])
makeLocal top arg typ val =
    case typ ^. _Pure of
    T.TFun f -> emplaceExtendArg (f ^. funcIn) arg <&> traverse . _2 %~ r <&> Just
    T.TVar{} -> emplaceArg arg <&> _2 %~ r & Just & pure
    _ -> pure Nothing
    where
        r = Ann (ExistingRef top) . V.BApp . App (writeNew val)

toFragOpt :: Annotated (Payload a m) # HoleOpt v name i o -> Annotated (Payload a m) # FragOpt v name i o
toFragOpt o =
    case o ^?! hVal . _HoleBinder . bBody of
    BinderTerm (BodyPostfixApply (PostfixApply a f)) ->
        reverse (f : match a)
        <&> annotation . plActions . detach .~ o ^. annotation . plActions . detach
        & FragPostfix & Ann (Const (f ^. annotation))
        where
            match (Ann _ (BodyPostfixApply (PostfixApply a' f'))) = f' : match a'
            match _ = []
    BinderTerm (BodySimpleApply a) ->
        a ^. appFunc
        & annValue %~
        \case
        BodyLeaf (LeafInject x) -> FragInject x
        BodyLeaf (LeafGetVar x) -> FragApplyFunc x
        _ -> error "unexpected result in fragment apply"
    BinderTerm (BodyLabeledApply x) ->
        FragOp FragOperator
        { _oFunc = x ^. aFunc
        , _oRightArg = x ^?! (aMOpArgs . Lens._Just . oaRhs <> aAnnotatedArgs . Lens.ix 1 . aaExpr)
        , _oAnnotatedArgs = x ^.. aAnnotatedArgs . traverse . aaTag
        } & Ann (Const (o ^. annotation))
    BinderTerm (BodyToNom n) -> n ^. nTId & FragToNom & Ann (Const (o ^. annotation))
    BinderTerm (BodyIfElse i) -> i ^. iThen & FragIf & Ann (Const (o ^. annotation))
    BinderTerm (BodyLam l) ->
        o & annValue .~
        case l ^. lamFunc . fParams of
        NullParam{} -> FragDefer
        _ -> FragLam
    BinderTerm (BodyRecord r) ->
        r ^?! cList . tlItems . Lens._Just . tlHead . tiTag & FragWrapInRec & Ann (Const (o ^. annotation))
    BinderTerm x -> error ("unexpected result in fragment result: " <> show (gconIndex x))
    BinderLet{} -> error "let in fragment result"
    & fixActions
    where
        -- HACK: The options represent the function or transformation used,
        -- But we want actions (at least fragment) to represent the whole transformed expression.
        -- Not really clear that this is the clean way to do it..
        fixActions = annotation . plActions . detach .~ o ^. annotation . plActions . detach

emplaceTag :: Monad m => FlatRowExtends T.Tag a b # h -> V.Var -> T m T.Tag
emplaceTag r v =
    Anchors.assocPresentationMode v & getP >>=
    \case
    Operator x _ -> pure x
    Verbose ->
        r ^.. freExtends . Lens.itraversed . Lens.asIndex
        & traverse (\x -> ExprIRef.readTagData x <&> \t -> (t ^. tagOrder, x))
        <&> snd . minimum . assertNotEmpty
    where
        assertNotEmpty [] = error "empty list!"
        assertNotEmpty x = x

emplaceArg :: Ann (Input.Payload m) # V.Term -> [(TypeMatch, Ann (Write m) # V.Term)]
emplaceArg arg =
    [ (TypeMatches, a)
    , (TypeMismatch, App (Ann WriteNew (V.BLeaf V.LHole)) a & V.BApp & Ann WriteNew)
    ]
    where
        a = arg & hflipped %~ hmap (const (ExistingRef . (^. Input.stored . ExprIRef.iref)))

emplaceExtendArg ::
    Monad m =>
    Pure # T.Type -> Ann (Input.Payload m) # V.Term ->
    T m [(TypeMatch, Ann (Write m) # V.Term)]
emplaceExtendArg typ arg =
    suggestVal typ <&>
    \s ->
    let h =
            case s ^. _Pure of
            V.BLeaf{} -> [] -- Redundant with plain emplace
            _ ->
                annContexts (writeNew s)
                ^.. ExprLens.valLeafs . V._LHole . Lens.asIndex
                <&> \(HFunc f :*: _) -> (TypeMatches, f a ^. Lens._Wrapped)
    in
    (TypeMatches, a) :
    (if length h == 1 then h else []) <>
    [(TypeMismatch, App (Ann WriteNew (V.BLeaf V.LHole)) a & V.BApp & Ann WriteNew)]
    where
        a = arg & hflipped %~ hmap (const (ExistingRef . (^. Input.stored . ExprIRef.iref)))

makeFromNom ::
    Monad m =>
    Input.Payload m # V.Term -> Ann (Input.Payload m) # V.Term ->
    Pure # T.Type -> NominalId ->
    T m (Result [(TypeMatch, Ann (Write m) # V.Term)])
makeFromNom topPl arg t tid =
    case t ^. _Pure of
    T.TVariant r ->
        suggestCase r (topPl ^. Input.inferredType) <&>
        \c ->
        simpleResult
        (fromNom WriteNew <&> _2 %~ Ann WriteNew . V.BApp . App (writeNew c))
        (const (fromNomTexts tid))
    _ -> simpleResult (fromNom (ExistingRef (topPl ^. Input.stored . ExprIRef.iref))) mempty & pure
    where
        fromNom w =
            emplaceArg arg
            <&> _2 %~ asHyper . Ann w . V.BApp . V.App (V._BLeaf . V._LFromNom # tid & Ann WriteNew)

fromNomTexts :: NominalId -> QueryLangInfo -> [Text]
fromNomTexts tid | tid == Builtins.boolTid = ifTexts
fromNomTexts _ = caseTexts

makeToNom ::
    Monad m =>
    Ann (Input.Payload m) # V.Term -> Pure # T.Type -> NominalId ->
    T m [(TypeMatch, Ann (Write m) # V.Term)]
makeToNom arg t tid =
    emplaceExtendArg t arg <&> Lens.mapped . _2 %~ Ann WriteNew . V.BToNom . V.ToNom tid

makeGetDef ::
    Monad m =>
    ExprIRef.ValI m -> Ann (Input.Payload m) # V.Term -> V.Var -> Pure # T.Type ->
    T m (Maybe [(TypeMatch, Ann (Write m) # V.Term)])
makeGetDef top arg v t =
    t ^? _Pure . T._TFun & Lens._Just %%~
    \f ->
    case f ^. funcIn of
    Pure (T.TRecord r@(Pure T.RExtend{})) ->
        do
            e <- emplaceTag flat v
            let ext rest x =
                    V.RowExtend
                    { V._eKey = e
                    , V._eVal = x
                    , V._eRest = rest
                    }
            rest <-
                T.flatRow # (flat & freExtends %~ Map.filterWithKey (\k _ -> k /= e)) & suggestRec
                <&> writeNew
            emplaceExtendArg (flat ^?! freExtends . Lens.ix e) arg
                <&> traverse . _2 %~
                    Ann WriteNew . V.BApp . App (Ann WriteNew (V.BLeaf (V.LVar v))) .
                    Ann WriteNew . V.BRecExtend . ext rest
        where
            flat = r ^. T.flatRow
    typ ->
        emplaceExtendArg typ arg
        <&> traverse . _2 %~ Ann (ExistingRef top) . V.BApp . App (Ann WriteNew (V.BLeaf (V.LVar v)))

toOpName :: Text -> Text
toOpName t = "." <> t <$ t ^? Lens._head . Lens.filtered Char.isAlpha & fromMaybe t
