{-# LANGUAGE CPP                       #-}
{-# LANGUAGE ExistentialQuantification          #-}

-- |
-- Module      : Streamly.Foldr.Types
-- Copyright   : (c) 2019 Composewell Technologies
-- License     : BSD3
-- Maintainer  : harendra.kumar@gmail.com
-- Stability   : experimental
-- Portability : GHC

module Streamly.Foldr.Types
    (
      Foldr (..)
    )
where

import Control.Applicative (liftA2)

------------------------------------------------------------------------------
-- Comonadic right folds
------------------------------------------------------------------------------

-- Foldl is a push based fold i.e. the producer calls the step function which in
-- turn calls the step functions of the composed folds and so on. Producer
-- has the control and pushes the whole stream inside the fold. The fold can
-- choose to use it or ignore it.
--
-- Foldr is a pull based fold i.e. the end consumers call their step functions
-- and demand the next value from the producer. As the end fold demands it in
-- turn will demand the values from the composed folds and so on, finally
-- demanding a value from the origin producer.
--
-- With Foldr we can branch out a stream into multiple different branches each
-- of which can pull lazily and terminate early. For example, we can try
-- different parses on a stream and then applicatively combine the results.
-- That way we can get all successful parses. Or we can compose differently and
-- select the first successful parse. If a parse fails we will not be consuming
-- the whole stream before we return, we can return as soon as it fails and try
-- the next one. Also, we will have the inputs consumed till now buffered so
-- that we can start the next fold from the beginning.
--
-- All parses are right folds in general. For example even "all/or/and"
-- combinators are acutally parses. Any early termination is a parse because it
-- can succeed or fail. Left folds always succeed, they do not have a failure.
-- For example the "length" combinator cannot fail.

-- Right folds are lazy puller computations. A composed right fold consumer or
-- comonadic right fold would pull from a common source and distribute the
-- input to multiple right folds in the composition. In comonadic left folds
-- the source pushes into each fold and therefore each fold recieves full input
-- irrespective of whether it uses it or not. In right folds we have pulling
-- computations and therefore they can terminate early and stop pulling. If all
-- the computations in a composed right fold stop pulling then the whole
-- computation terminates. The source needs to copy and distribute the input,
-- therefore it needs to retain an input until it has been pulled by all the
-- folds in a composition.
--
-- Now we can compose the consuming folds in different ways. One, all the
-- results are to be used ultimately (applicative). Two, only one of the
-- results is chosen (alternative). In a monoidal composition the outputs of
-- all the folds can be merged into a single lazy stream.
--
-- To implement composition of right folds we probably need a puller that pulls
-- and distributes the input to individual folds. there are multiple ways to
-- have multiple consumers pulling:
--
-- * when an element is pulled/demanded by any of the folds we queue it to all
-- the folds, each fold has its own buffer. This way we need a buffer but
-- different folds can run at different speeds.
--
-- * When a fold demands an element it is made to wait until the element has
-- been consumed by all folds, therefore all folds run at the speed of the
-- slowest fold. This is in fact a special case of the buffered case, in this
-- case we have a single element buffer.



-- | Represents a right fold from a container of values of type @a@ to a single
-- value of type @b@ in 'Monad' @m@. Each step of the fold can be applied
-- incrementally by explicitly calling the @step@ function and the accumulated
-- value can be extracted at any point by calling the @extract@ function.
--
data Foldr m a b =
  -- | @Foldr@ @step@ @final@
  Foldr (a -> b -> m b) (m b)

-- In an alternative composition all folds can receive the same type of input
-- and one of them is chosen.

{-
instance Functor m => Functor (Foldr m a) where
    {-# INLINE fmap #-}
    fmap f (Foldr step start done) = Foldr step start done'
      where
        done' x = fmap f $! done x

instance Applicative m => Applicative (Foldr m a) where
    {-# INLINE pure #-}
    pure b = Foldr (\() _ -> pure ()) (pure ()) (\() -> pure b)

    {-# INLINE (<*>) #-}
    (Foldr stepL beginL doneL) <*> (Foldr stepR beginR doneR) =
        let step (Pair xL xR) a = Pair <$> stepL xL a <*> stepR xR a
            begin = Pair <$> beginL <*> beginR
            done (Pair xL xR) = doneL xL <*> doneR xR
        in  Foldr step begin done

instance (Semigroup b, Monad m) => Semigroup (Foldr m a b) where
    {-# INLINE (<>) #-}
    (<>) = liftA2 (<>)

instance (Monoid b, Monad m) => Monoid (Foldr m a b) where
    {-# INLINE mempty #-}
    mempty = pure mempty

    {-# INLINE mappend #-}
    mappend = (<>)

instance (Monad m, Num b) => Num (Foldr m a b) where
    {-# INLINE fromInteger #-}
    fromInteger = pure . fromInteger

    {-# INLINE negate #-}
    negate = fmap negate

    {-# INLINE abs #-}
    abs = fmap abs

    {-# INLINE signum #-}
    signum = fmap signum

    {-# INLINE (+) #-}
    (+) = liftA2 (+)

    {-# INLINE (*) #-}
    (*) = liftA2 (*)

    {-# INLINE (-) #-}
    (-) = liftA2 (-)

instance (Monad m, Fractional b) => Fractional (Foldr m a b) where
    {-# INLINE fromRational #-}
    fromRational = pure . fromRational

    {-# INLINE recip #-}
    recip = fmap recip

    {-# INLINE (/) #-}
    (/) = liftA2 (/)

instance (Monad m, Floating b) => Floating (Foldr m a b) where
    {-# INLINE pi #-}
    pi = pure pi

    {-# INLINE exp #-}
    exp = fmap exp

    {-# INLINE sqrt #-}
    sqrt = fmap sqrt

    {-# INLINE log #-}
    log = fmap log

    {-# INLINE sin #-}
    sin = fmap sin

    {-# INLINE tan #-}
    tan = fmap tan

    {-# INLINE cos #-}
    cos = fmap cos

    {-# INLINE asin #-}
    asin = fmap asin

    {-# INLINE atan #-}
    atan = fmap atan

    {-# INLINE acos #-}
    acos = fmap acos

    {-# INLINE sinh #-}
    sinh = fmap sinh

    {-# INLINE tanh #-}
    tanh = fmap tanh

    {-# INLINE cosh #-}
    cosh = fmap cosh

    {-# INLINE asinh #-}
    asinh = fmap asinh

    {-# INLINE atanh #-}
    atanh = fmap atanh

    {-# INLINE acosh #-}
    acosh = fmap acosh

    {-# INLINE (**) #-}
    (**) = liftA2 (**)

    {-# INLINE logBase #-}
    logBase = liftA2 logBase
    -}
