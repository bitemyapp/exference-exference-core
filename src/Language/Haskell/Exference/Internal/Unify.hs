module Language.Haskell.Exference.Internal.Unify
  ( unify
  , unifyRight
  )
where



import Language.Haskell.Exference.Types
import qualified Data.Map.Strict as M
import Data.Maybe

import Debug.Hood.Observe
import Debug.Trace



type TypeEq = (HsType, HsType)

data UniState = UniState [TypeEq] Substs

occursIn :: TVarId -> HsType -> Bool
occursIn i (TypeVar j)         = i==j
occursIn _ (TypeConstant _)    = False
occursIn _ (TypeCons _)        = False
occursIn i (TypeArrow t1 t2)   = occursIn i t1 || occursIn i t2
occursIn i (TypeApp t1 t2)     = occursIn i t1 || occursIn i t2
occursIn i (TypeForall js _ t) = not (i `elem` js) && occursIn i t

unify :: HsType -> HsType -> Maybe Substs
unify ut1 ut2 = unify' $ UniState [(ut1, ut2)] M.empty
  where
    unify' :: UniState -> Maybe Substs
    unify' (UniState [] x)      = Just x
    unify' (UniState (x:xr) ss) = uniStep x >>= (
      \r -> unify' $ case r of
        Left subst -> let f = applySubst subst in UniState
          [(f a, f b) | (a,b) <- xr]
          (uncurry M.insert subst $ M.map f ss)
        Right eqs -> UniState (eqs++xr) ss
      )
    uniStep :: (HsType, HsType) -> Maybe (Either Subst [TypeEq])
    uniStep (TypeVar i1, TypeVar i2) | i1==i2 = Just (Right [])
    uniStep (TypeVar i1, t2) = if occursIn i1 t2
      then Nothing
      else Just (Left (i1, t2))
    uniStep (t1, v@(TypeVar _)) = uniStep (v, t1)
    uniStep (TypeConstant i1, TypeConstant i2) | i1==i2 = Just (Right [])
    uniStep (TypeCons s1, TypeCons s2) | s1==s2 = Just (Right [])
    uniStep (TypeArrow t1 t2, TypeArrow t3 t4) = Just (Right [(t1,t3),(t2,t4)])
    uniStep (TypeApp t1 t2, TypeApp t3 t4) = Just (Right [(t1, t3), (t2, t4)])
    -- TODO TypeForall unification
    -- THIS IS WRONG; WE IGNORE FORALLS FOR THE MOMENT
    uniStep (TypeForall _ _ t1, t2) = uniStep (t1, t2)
    uniStep (t1, TypeForall _ _ t2) = uniStep (t1, t2)
    uniStep _ = Nothing

-- treats the variables in the first parameter as constants, and returns
-- the variable bindings for the second parameter that unify both types.
unifyRight :: HsType -> HsType -> Maybe Substs
unifyRight ut1 ut2 = unify' $ UniState [(ut1, ut2)] M.empty
  where
    unify' :: UniState -> Maybe Substs
    unify' (UniState [] x) = Just x
    unify' (UniState (x:xr) ss) = uniStep x >>= (
      \r -> unify' $ case r of
        Left subst -> let f = applySubst subst in UniState
          [(f a, f b) | (a,b) <- xr]
          (uncurry M.insert subst $ M.map f ss)
        Right eqs -> UniState (eqs++xr) ss
      )
    uniStep :: (HsType, HsType) -> Maybe (Either Subst [TypeEq])
    uniStep (TypeVar i1, TypeVar i2) | i1==i2 = Just (Right [])
    uniStep (t1, TypeVar i2) = if occursIn i2 t1
      then Nothing
      else Just (Left (i2, t1))
    uniStep (TypeVar _, _) = Nothing
    uniStep (TypeConstant i1, TypeConstant i2) | i1==i2 = Just (Right [])
    uniStep (TypeCons s1, TypeCons s2) | s1==s2 = Just (Right [])
    uniStep (TypeArrow t1 t2, TypeArrow t3 t4) = Just (Right [(t1,t3),(t2,t4)])
    uniStep (TypeApp t1 t2, TypeApp t3 t4) = Just (Right [(t1, t3), (t2, t4)])
    -- TODO TypeForall unification
    -- THIS IS WRONG; WE IGNORE FORALLS FOR THE MOMENT
    uniStep (TypeForall _ _ t1, t2) = uniStep (t1, t2)
    uniStep (t1, TypeForall _ _ t2) = uniStep (t1, t2)
    uniStep _ = Nothing

--unifyDist :: HsType -> HsType -> Maybe Substs
--unifyDist t1 t2 = unify t1 $ distinctify t1 t2

-- tries to unify two types, under the assumption that one is supposed
-- to serve as the parameter (at some levels) to the other one (when at
-- least one is a function, that is.)
-- either is BROKEN, or does something other than i expected.
-- not used (or needed) anyway, so.. deletion candidate.
{-
inflateUnify :: HsType -> HsType -> [HsType]
inflateUnify t1 t2 =
  let d1 = arrowDepth t1
      d2 = arrowDepth t2
  in if d1 > d2
    then f t1 $ inflateTo d1 t2
    else f t2 $ inflateTo d2 t1
  where
    inflateTo :: Int -> HsType -> [HsType]
    inflateTo n t = map (createArrow t (map TypeVar [1000..998+n])) [0..n-1]
    createArrow t varIds i =
      let (l,r) = splitAt i varIds
          types = l++[t]++r
      in foldr1 TypeArrow types
    f :: HsType -> [HsType] -> [HsType]
    f ft1 ft2s = catMaybes [g ft1 (distinctify ft1 ft2) | ft2 <- ft2s]
    g :: HsType -> HsType -> Maybe HsType
    g gt1 gt2 = fmap (\subst -> reduceIds $ applySubsts subst gt1) (unify gt1 gt2)
-}
