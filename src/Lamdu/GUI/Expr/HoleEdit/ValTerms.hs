{-# LANGUAGE TypeFamilies #-}
module Lamdu.GUI.Expr.HoleEdit.ValTerms
    ( holeSearchTerm
    , allowedSearchTermCommon
    , allowedFragmentSearchTerm
    , getSearchStringRemainder
    , verifyInjectSuffix
    , definitePart
    ) where

import qualified Control.Lens as Lens
import qualified Data.Char as Char
import qualified Data.Text as Text
import qualified GUI.Momentu.Widgets.Menu.Search as SearchMenu
import           Hyper
import qualified Lamdu.CharClassification as Chars
import qualified Lamdu.I18N.Code as Texts
import qualified Lamdu.I18N.CodeUI as Texts
import           Lamdu.Name (Name(..), Collision(..))
import qualified Lamdu.Name as Name
import           Lamdu.Sugar.Types

import           Lamdu.Prelude

collisionText :: Name.Collision -> Text
collisionText NoCollision = ""
collisionText (Collision i) = Text.pack (show i)
collisionText UnknownCollision = "?"

ofName :: Name -> [Text]
ofName Name.Unnamed{} = []
ofName (Name.AutoGenerated text) = [text]
ofName (Name.NameTag x) =
    [ displayName
        <> collisionText textCollision
        <> collisionText (x ^. Name.tnTagCollision)
    ]
    where
        Name.TagText displayName textCollision = x ^. Name.tnDisplayText

holeSearchTerm ::
    (Has (Texts.Code Text) env, Has (Texts.CodeUI Text) env) =>
    env -> HoleTerm Name -> [Text]
holeSearchTerm _ (HoleGetDef x) =
    ofName x >>= maybePrefixDot
    where
        maybePrefixDot n
            | Name.isOperator x = [n]
            | otherwise = [n, "." <> n]
holeSearchTerm _ (HoleName x) = ofName x
holeSearchTerm _ (HoleGetField x) = ofName x <&> ("." <>)
holeSearchTerm _ (HoleInject x) = (<>) <$> ofName x <*> [":", "."]
holeSearchTerm e HoleLet = [e ^. has . Texts.let_]
holeSearchTerm e HoleLambda = [e ^. has . Texts.lambda, "\\", "Λ", "λ", "->", "→"]
holeSearchTerm e HoleIf = [e ^. has . Texts.if_, ":"]
holeSearchTerm e HoleCase = [e ^. has . Texts.case_]
holeSearchTerm e HoleEmptyCase = [e ^. has . Texts.absurd]
holeSearchTerm _ HoleRecord = ["{}", "()", "[]"]
holeSearchTerm e HoleParamsRecord = [e ^. has . Texts.paramsRecordOpener]

type Suffix = Char

allowedSearchTermCommon :: [Suffix] -> Text -> Bool
allowedSearchTermCommon suffixes searchTerm =
    any (searchTerm &)
    [ Text.all (`elem` Chars.operator)
    , isAlphaNumericName
    , (`Text.isPrefixOf` "{}")
    , (== "\\")
    , Lens.has (Lens.reversed . Lens._Cons . Lens.filtered inj)
    , -- Allow typing records in wrong direction of keyboard input,
      -- for example when editing in right-to-left but not switching the input language.
      -- Then the '}' key would had inserted a '{' but inserts a '}'.
      -- In this case it would probably help to still allow it
      -- as the user intended to create a record.
      (== "}")
    ]
    where
        inj (lastChar, revInit) =
            lastChar `elem` suffixes && Text.all Char.isAlphaNum revInit

isAlphaNumericName :: Text -> Bool
isAlphaNumericName t =
    case Text.uncons t of
    Nothing -> True
    Just ('.', xs) -> isAlphaNumericSuffix xs
    Just _ -> isAlphaNumericSuffix t
    where
        isAlphaNumericSuffix suffix =
            case Text.uncons suffix of
            Nothing -> True
            Just (x, xs) -> Char.isAlpha x && Text.all Char.isAlphaNum xs

allowedFragmentSearchTerm :: Text -> Bool
allowedFragmentSearchTerm searchTerm =
    allowedSearchTermCommon ":" searchTerm || isGetField searchTerm
    where
        isGetField t =
            case Text.uncons t of
            Just (c, rest) -> c == '.' && Text.all Char.isAlphaNum rest
            Nothing -> False

-- | Given a hole result sugared expression, determine which part of
-- the search term is a remainder and which belongs inside the hole
-- result expr
getSearchStringRemainder :: SearchMenu.ResultsContext -> Term v name i o # Ann a -> Text
getSearchStringRemainder ctx holeResult
    | isA _BodyInject = ""
      -- NOTE: This is wrong for operator search terms like ".." which
      -- should NOT have a remainder, but do. We might want to correct
      -- that.  However, this does not cause any bug because search
      -- string remainders are genreally ignored EXCEPT in
      -- apply-operator, which does not occur when the search string
      -- already is an operator.
    | isSuffixed ":" = ":"
    | isSuffixed "." = "."
    | otherwise = ""
    where
        isSuffixed suffix = Text.isSuffixOf suffix (ctx ^. SearchMenu.rSearchTerm)
        fragmentExpr = _BodyFragment . fExpr
        isA x = any (`Lens.has` holeResult) [x, fragmentExpr . hVal . x]

verifyInjectSuffix :: Text -> Term v name i o f -> Bool
verifyInjectSuffix searchTerm x =
    case suffix of
    Just ':' | Lens.has (injectContent . _InjectNullary) x -> False
    Just '.' | Lens.has (injectContent . _InjectVal) x -> False
    _ -> True
    where
        suffix = searchTerm ^? Lens.reversed . Lens._Cons . _1
        injectContent = _BodyInject . iContent

-- | Returns the part of the search term that is DEFINITELY part of
-- it. Some of the stripped suffix may be part of the search term,
-- depending on the val.
definitePart :: Text -> Text
definitePart searchTerm
    | Text.any Char.isAlphaNum searchTerm
    && any (`Text.isSuffixOf` searchTerm) [":", "."] = Text.init searchTerm
    | otherwise = searchTerm
