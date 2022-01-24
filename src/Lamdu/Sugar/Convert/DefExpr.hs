{-# LANGUAGE TypeApplications #-}
module Lamdu.Sugar.Convert.DefExpr
    ( convert
    ) where

import qualified Control.Lens as Lens
import           Control.Monad.Once (OnceT)
import qualified Data.Property as Property
import           Hyper.Syntax.Scheme (saveScheme)
import           Hyper.Unify (UVar)
import           Hyper.Unify.Generalize (generalize)
import           Lamdu.Calc.Infer (alphaEq, runPureInfer)
import qualified Lamdu.Calc.Term as V
import qualified Lamdu.Calc.Type as T
import qualified Lamdu.Data.Definition as Definition
import           Lamdu.Expr.IRef (DefI)
import qualified Lamdu.Expr.IRef as ExprIRef
import           Lamdu.Sugar.Convert.Binder (convertDefinitionBinder)
import qualified Lamdu.Sugar.Convert.Input as Input
import           Lamdu.Sugar.Convert.Monad (ConvertM)
import qualified Lamdu.Sugar.Convert.Monad as ConvertM
import qualified Lamdu.Sugar.Convert.Type as ConvertType
import           Lamdu.Sugar.Internal
import qualified Lamdu.Sugar.Internal.EntityId as EntityId
import           Lamdu.Sugar.Types
import           Revision.Deltum.Transaction (Transaction)
import           Text.PrettyPrint.HughesPJClass (Pretty(..))

import           Lamdu.Prelude

type T = Transaction

convert ::
    Monad m =>
    Pure # T.Scheme ->
    Definition.Expr (Ann (Input.Payload m) # V.Term) ->
    DefI m ->
    ConvertM m (DefinitionBody EvalPrep InternalName (OnceT (T m)) (T m) (ConvertPayload m))
convert defType defExpr defI =
    do
        (presMode, content) <-
            convertDefinitionBinder defI (defExpr ^. Definition.expr)
        inferContext <- Lens.view ConvertM.scInferContext
        let inferredType =
                generalize (defExpr ^. Definition.expr . hAnn . Input.inferredTypeUVar)
                >>= saveScheme
                & runPureInfer @(V.Scope # UVar) V.emptyScope inferContext
                & (^?! Lens._Right . _1)
        unless (alphaEq defType inferredType) $
            error $ "Def type mismatches its inferred type! " <> show (pPrint (defType, inferredType))
        defTypeS <- ConvertType.convertScheme (EntityId.currentTypeOf entityId) defType
        DefinitionBodyExpression DefinitionExpression
            { _deType = defTypeS
            , _dePresentationMode = presMode <&> (^. Property.mkProperty) <&> lift
            , _deContent = content
            } & pure
    where
        entityId = ExprIRef.globalId defI & EntityId.ofBinder
