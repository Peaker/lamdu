{-# LANGUAGE TypeFamilies #-}
module Lamdu.Sugar.Convert.Case
    ( convert
    , convertAbsurd
    , convertAppliedCase
    ) where

import qualified Control.Lens as Lens
import           Control.Monad.Trans.Maybe (MaybeT(..))
import           Data.Maybe.Extended (maybeToMPlus)
import           Hyper (_ANode)
import           Hyper.Type.AST.Row (RowExtend(..))
import qualified Lamdu.Calc.Term as V
import qualified Lamdu.Calc.Type as T
import qualified Lamdu.Data.Ops as DataOps
import qualified Lamdu.Expr.IRef as ExprIRef
import qualified Lamdu.Sugar.Config as Config
import qualified Lamdu.Sugar.Convert.Composite as Composite
import           Lamdu.Sugar.Convert.Expression.Actions (addActions)
import           Lamdu.Sugar.Convert.IfElse (convertIfElse)
import qualified Lamdu.Sugar.Convert.Input as Input
import           Lamdu.Sugar.Convert.Monad (ConvertM)
import qualified Lamdu.Sugar.Convert.Monad as ConvertM
import           Lamdu.Sugar.Internal
import qualified Lamdu.Sugar.Internal.EntityId as EntityId
import           Lamdu.Sugar.Types

import           Lamdu.Prelude

-- This is mostly a copy&paste of the Convert.Record module, yuck! DRY
-- with some abstraction?

convertAbsurd ::
    (Monad m, Monoid a) =>
    Input.Payload m a # V.Term -> ConvertM m (ExpressionU v m a)
convertAbsurd pl =
    Composite.convertEmpty DataOps.case_ pl
    <&> Case LambdaCase
    <&> BodyCase
    >>= addActions (Const ()) pl

_CaseThatIsLambdaCase :: Lens.Prism' (Case v name i o # k) (Composite v name i o # k)
_CaseThatIsLambdaCase =
    Lens.prism' (Case LambdaCase) $ \case
    Case LambdaCase x -> Just x
    _ -> Nothing

convert ::
    (Monad m, Monoid a) =>
    RowExtend T.Tag V.Term V.Term # Ann (Input.Payload m a) ->
    Input.Payload m a # V.Term ->
    ConvertM m (ExpressionU EvalPrep m a)
convert (RowExtend tag v rest) exprPl =
    do
        valS <-
            ConvertM.convertSubexpression v
            <&> hVal . _BodyLam . lamApplyLimit .~ AtMostOneFuncApply
        restS <- ConvertM.convertSubexpression rest
        let caseP =
                Composite.ExtendVal
                { Composite._extendTag = tag
                , Composite._extendValI = v ^. hAnn . Input.stored . ExprIRef.iref
                , Composite._extendRest = rest ^. hAnn
                }
        Composite.convert DataOps.case_ V.LAbsurd mkCase (_BodyCase . _CaseThatIsLambdaCase) valS restS
            exprPl caseP
    where
        mkCase t c r = RowExtend t c r & V.BCase

convertAppliedCase ::
    (Monad m, Monoid a) =>
    V.App V.Term # Ann (Input.Payload m a) ->
    ExpressionU v m a -> ExpressionU v m a -> Input.Payload m a # V.Term ->
    MaybeT (ConvertM m) (ExpressionU v m a)
convertAppliedCase (V.App _ arg) funcS argS exprPl =
    do
        Lens.view (ConvertM.scConfig . Config.sugarsEnabled . Config.caseWithArgument) >>= guard
        caseB <- funcS ^? hVal . _BodyCase & maybeToMPlus
        Lens.has (cKind . _LambdaCase) caseB & guard
        protectedSetToVal <- lift ConvertM.typeProtectedSetToVal
        let setTo = protectedSetToVal (exprPl ^. Input.stored)
        let appliedCaseB =
                caseB
                & cKind .~ CaseWithArg
                    CaseArg
                    { _caVal = argS
                    , _caToLambdaCase =
                        setTo (funcS ^. annotation . pInput . Input.stored . ExprIRef.iref)
                        <&> EntityId.ofValI
                    }
        ifSugar <- Lens.view (ConvertM.scConfig . Config.sugarsEnabled . Config.ifExpression)
        guard ifSugar *> convertIfElse setTo appliedCaseB
            & maybe (BodyCase appliedCaseB) BodyIfElse
            -- func will be our entity id, so remove it from the hidden ids
            & addActions (_ANode # arg) exprPl & lift
            <&> annotation . pInput . Input.entityId .~ funcS ^. annotation . pInput . Input.entityId
            <&> annotation . pInput . Input.userData <>~
                exprPl ^. Input.userData <> funcS ^. annotation . pInput . Input.userData
