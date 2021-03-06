{-# LANGUAGE DeriveGeneric #-}

module Language.Haskell.Exference.Types
  ( TVarId
  , QualifiedName(..)
  , HsType (..)
  , Subst
  , Substs
  , HsTypeClass (..)
  , HsInstance (..)
  , HsConstraint (..)
  , StaticClassEnv (..)
  , QueryClassEnv ( qClassEnv_env
                  , qClassEnv_constraints
                  , qClassEnv_inflatedConstraints
                  , qClassEnv_varConstraints )
  , constraintApplySubsts
  , inflateHsConstraints
  , applySubst
  , applySubsts
  , typeParser
  , containsVar
  , showVar
  , mkQueryClassEnv
  , addQueryClassEnv
  , freeVars
  )
where



import Data.Char ( ord, chr, isLower, isUpper )
import Data.List ( intercalate, intersperse )
import Data.Foldable ( fold, foldMap )
import Control.Applicative ( (<$>), (<*>), (*>), (<*) )
import Data.Maybe ( maybeToList, fromMaybe )

import qualified Data.Set as S
import qualified Data.Map.Strict as M

import Text.ParserCombinators.Parsec hiding (State)
import Text.ParserCombinators.Parsec.Char

import Control.DeepSeq.Generics
import GHC.Generics

import Debug.Hood.Observe



type TVarId = Int
type Subst  = (TVarId, HsType)
type Substs = M.Map TVarId HsType

data QualifiedName
  = QualifiedName [String] String
  | ListCon
  | TupleCon Int
  | Cons
  deriving (Eq, Ord, Generic)

data HsType = TypeVar      TVarId
            | TypeConstant TVarId  -- like TypeCons, for exference-internal
                                   -- purposes.
            | TypeCons     QualifiedName
            | TypeArrow    HsType HsType
            | TypeApp      HsType HsType
            | TypeForall   [TVarId] [HsConstraint] HsType
  deriving (Ord, Eq, Generic)

data HsTypeClass = HsTypeClass
  { tclass_name :: QualifiedName
  , tclass_params :: [TVarId]
  , tclass_constraints :: [HsConstraint]
  }
  deriving (Eq, Show, Ord, Generic)

data HsInstance = HsInstance
  { instance_constraints :: [HsConstraint]
  , instance_tclass :: HsTypeClass
  , instance_params :: [HsType]
  }
  deriving (Eq, Show, Ord, Generic)

data HsConstraint = HsConstraint
  { constraint_tclass :: HsTypeClass
  , constraint_params :: [HsType]
  }
  deriving (Eq, Ord, Generic)

data StaticClassEnv = StaticClassEnv
  { sClassEnv_tclasses :: [HsTypeClass]
  , sClassEnv_instances :: M.Map QualifiedName [HsInstance]
  }
  deriving (Show, Generic)

data QueryClassEnv = QueryClassEnv
  { qClassEnv_env :: StaticClassEnv
  , qClassEnv_constraints :: S.Set HsConstraint
  , qClassEnv_inflatedConstraints :: S.Set HsConstraint
  , qClassEnv_varConstraints :: M.Map TVarId (S.Set HsConstraint)
  }
  deriving (Generic)

instance NFData QualifiedName  where rnf = genericRnf
instance NFData HsType         where rnf = genericRnf
instance NFData HsTypeClass    where rnf = genericRnf
instance NFData HsInstance     where rnf = genericRnf
instance NFData HsConstraint   where rnf = genericRnf
instance NFData StaticClassEnv where rnf = genericRnf
instance NFData QueryClassEnv  where rnf = genericRnf

instance Show QualifiedName where
  show (QualifiedName ns n) = if    length n >= 2
                                 && head n == '('
                                 && last n == ')'
                              then "(" ++ intercalate "." (ns ++ [tail n])
                              else        intercalate "." (ns ++ [n])
  show ListCon              = "[]"
  show (TupleCon 0)         = "()"
  show (TupleCon i)         = "(" ++ replicate (i-1) ',' ++ ")"
  show Cons                 = "(:)"

instance Show HsType where
  showsPrec _ (TypeVar i) = showString $ showVar i
  showsPrec _ (TypeConstant i) = showString $ "C" ++ showVar i
  showsPrec d (TypeCons s) = showsPrec d s
  showsPrec d (TypeArrow t1 t2) =
    showParen (d> -2) $ showsPrec (-1) t1 . showString " -> " . showsPrec (-1) t2
  showsPrec d (TypeApp t1 t2) =
    showParen (d> -1) $ showsPrec 0 t1 . showString " " . showsPrec 0 t2
  showsPrec d (TypeForall [] [] t) = showsPrec d t
  showsPrec d (TypeForall is cs t) =
    showParen (d>0)
    $ showString ("forall " ++ intercalate ", " (showVar <$> is) ++ " . ")
    . showParen True (\x -> foldr (++) x $ intersperse ", " $ map show cs)
    . showString " => "
    . showsPrec (-2) t

instance Observable HsType where
  observer x = observeOpaque (show x) x

instance Read HsType where
  readsPrec _ = maybeToList . parseType

instance Show HsConstraint where
  show (HsConstraint c ps) = unwords $ show (tclass_name c) : map show ps

instance Show QueryClassEnv where
  show (QueryClassEnv _ cs _ _) = "(QueryClassEnv _ " ++ show cs ++ " _)"
instance Observable HsConstraint where
  observer x = observeOpaque (show x) x

instance Observable QueryClassEnv where
  observer x = observeOpaque (show x) x

instance Observable HsInstance where
  observer x = observeOpaque (show x) x

filterHsConstraintsByVarId :: TVarId
                           -> S.Set HsConstraint
                           -> S.Set HsConstraint
filterHsConstraintsByVarId i = S.filter
                             $ any (containsVar i) . constraint_params

containsVar :: TVarId -> HsType -> Bool
containsVar i = S.member i . freeVars

mkQueryClassEnv :: StaticClassEnv -> [HsConstraint] -> QueryClassEnv
mkQueryClassEnv sClassEnv constrs = addQueryClassEnv constrs $ QueryClassEnv {
  qClassEnv_env = sClassEnv,
  qClassEnv_constraints = S.empty,
  qClassEnv_inflatedConstraints = S.empty,
  qClassEnv_varConstraints = M.empty
}

addQueryClassEnv :: [HsConstraint] -> QueryClassEnv -> QueryClassEnv
addQueryClassEnv constrs env = env {
  qClassEnv_constraints = csSet,
  qClassEnv_inflatedConstraints = inflateHsConstraints csSet,
  qClassEnv_varConstraints = helper constrs
}
  where
    csSet = S.fromList constrs `S.union` qClassEnv_constraints env
    helper :: [HsConstraint] -> M.Map TVarId (S.Set HsConstraint)
    helper cs =
      let ids :: S.Set TVarId
          ids = fold $ freeVars <$> (constraint_params =<< cs)
      in M.fromSet (flip filterHsConstraintsByVarId
                    $ inflateHsConstraints csSet) ids

inflateHsConstraints :: S.Set HsConstraint -> S.Set HsConstraint
inflateHsConstraints = inflate (S.fromList . f)
  where
    f :: HsConstraint -> [HsConstraint]
    f (HsConstraint (HsTypeClass _ ids constrs) ps) =
      map (constraintApplySubsts $ M.fromList $ zip ids ps) constrs

-- uses f to find new elements. adds these new elements, and recursively
-- tried to find even more elements. will not terminate if there are cycles
-- in the application of f
inflate :: (Ord a, Show a) => (a -> S.Set a) -> S.Set a -> S.Set a
inflate f = fold . S.fromList . iterateWhileNonempty (foldMap f)
  where
    iterateWhileNonempty g x = if S.null x
      then []
      else x : iterateWhileNonempty g (g x)

constraintApplySubst :: Subst -> HsConstraint -> HsConstraint
constraintApplySubst s (HsConstraint c ps) =
  HsConstraint c $ map (applySubst s) ps

constraintApplySubsts :: Substs -> HsConstraint -> HsConstraint
constraintApplySubsts ss (HsConstraint c ps) =
  HsConstraint c $ map (applySubsts ss) ps

showVar :: TVarId -> String
showVar i = if i<26 then [chr (ord 'a' + i)] else "t"++show (i-26)

parseType :: String -> Maybe (HsType, String)
parseType s = either (const Nothing) Just
            $ runParser (    (,)
                         <$> typeParser
                         <*> many anyChar)
                        ()
                        ""
                        s

typeParser :: Parser HsType
typeParser = parseAll
  where
    parseAll :: Parser HsType
    parseAll = parseUn >>= parseBin
    parseUn :: Parser HsType -- TODO: forall
    parseUn = spaces *> (
            try (TypeCons . QualifiedName [] <$> ((:) <$> satisfy isUpper <*> many alphaNum))
        <|> try ((TypeVar . (\x -> x - ord 'a') . ord) <$> satisfy isLower)
        <|>     (char '(' *> parseAll <* char ')')
      )
    parseBin :: HsType -> Parser HsType
    parseBin left =
        try (    try (TypeArrow left <$> (spaces *> string "->" *> parseAll))
             <|>     ((TypeApp   left <$> (space *> parseUn)) >>= parseBin)
             )
        <|>
        (spaces *> return left)

applySubst :: Subst -> HsType -> HsType
applySubst (i, t) v@(TypeVar j) = if i==j then t else v
applySubst _ c@(TypeConstant _) = c
applySubst _ c@(TypeCons _)     = c
applySubst s (TypeArrow t1 t2)  = TypeArrow (applySubst s t1) (applySubst s t2)
applySubst s (TypeApp t1 t2)    = TypeApp (applySubst s t1) (applySubst s t2)
applySubst s@(i,_) f@(TypeForall js cs t) = if elem i js
  then f
  else TypeForall js (constraintApplySubst s <$> cs) (applySubst s t)

applySubsts :: Substs -> HsType -> HsType
applySubsts s v@(TypeVar i)      = fromMaybe v $ M.lookup i s
applySubsts _ c@(TypeConstant _) = c
applySubsts _ c@(TypeCons _)     = c
applySubsts s (TypeArrow t1 t2)  = TypeArrow (applySubsts s t1) (applySubsts s t2)
applySubsts s (TypeApp t1 t2)    = TypeApp (applySubsts s t1) (applySubsts s t2)
applySubsts s (TypeForall js cs t) = TypeForall
                                       js
                                       (constraintApplySubsts s <$> cs)
                                       (applySubsts (foldr M.delete s js) t)

freeVars :: HsType -> S.Set TVarId
freeVars (TypeVar i)         = S.singleton i
freeVars (TypeConstant _)    = S.empty
freeVars (TypeCons _)        = S.empty
freeVars (TypeArrow t1 t2)   = S.union (freeVars t1) (freeVars t2)
freeVars (TypeApp t1 t2)     = S.union (freeVars t1) (freeVars t2)
freeVars (TypeForall is _ t) = foldr S.delete (freeVars t) is
