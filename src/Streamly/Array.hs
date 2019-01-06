{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE ScopedTypeVariables #-}

#include "Streams/inline.hs"

-- |
-- Module      : Streamly.Array
-- Copyright   : (c) 2019 Harendra Kumar
--
-- License     : BSD3
-- Maintainer  : harendra.kumar@gmail.com
-- Stability   : experimental
-- Portability : GHC
--
-- Arrays are chunks of memory that can hold a /finite/ sequence of values of
-- the same type. Unlike streams, vectors are /finite/ and therefore most of the
-- APIs dealing with vectors specify the size of the vector. The size of a
-- vector is pre-determined unlike streams where we need to compute the length
-- by traversing the entire stream.
--
-- Most importantly, vectors as implemented in this module, use memory that is
-- out of the ambit of GC and therefore add no pressure to GC. Moreover, they
-- can be used to communicate with foreign consumers and producers (e.g. file
-- and network IO) with zero copy.
--
-- Arrays help reduce GC pressure when we want to hold large amounts of data
-- in memory. Too many small vectors (e.g. single byte) are only as good as
-- holding data in a Haskell list. However, small vectors can be compacted into
-- large ones to reduce the overhead. To hold 32GB memory in 32k sized buffers
-- we need 1 million vectors if we use a vector for each chunk. This is still
-- significant to add pressure to GC.  However, we can create vectors of
-- vectors (trees) to scale to arbitrarily large amounts of memory but still
-- using small chunks of contiguous memory.

-------------------------------------------------------------------------------
-- Design Notes
-------------------------------------------------------------------------------

-- There are two goals that we need to fulfill and use vectors to fulfill them.
-- One, holding large amounts of data in non-GC memory, two, allow random
-- access to elements based on index. The first one falls in the category of
-- storage buffers while the second one falls in the category of
-- maps/multisets/hashmaps.
--
-- For the first requirement we use a vector of Storables. We can have both
-- immutable and mutable variants of this vector using wrappers over the same
-- underlying type.
--
-- For the second requirement we can provide a vector of polymorphic elements
-- that need not be Storable instances. In that case we need to use an Array#
-- instead of a ForeignPtr. This type of vector would not reduce the GC
-- overhead as much because each element of the array still needs to be scanned
-- by the GC.  However, this would allow random access to the elements. But in
-- most cases random access means storage, and it means we need to avoid GC
-- scanning except in cases of trivially small storage. One way to achieve that
-- would be to put the array in a Compact region. However, when we mutate this,
-- we will have to use a manual GC copying out to another CR and freeing the
-- old one.

-------------------------------------------------------------------------------
-- SIMD Arrays
-------------------------------------------------------------------------------

-- XXX Try using SIMD operations where possible to combine vectors and to fold
-- vectors. For example computing checksums of streams, adding streams or
-- summing streams.

-------------------------------------------------------------------------------
-- Caching coalescing/batching
-------------------------------------------------------------------------------

-- XXX we can use address tags in IO buffers to coalesce multiple buffers into
-- fewer IO requests. Similarly we can split responses to serve them to the
-- right consumers. This will be comonadic. A common buffer cache can be
-- maintained which can be shared by many consumers.
--
-- XXX we can also have IO error monitors attached to streams. to monitor disk
-- or network errors or latencies and then take actions for example starting a
-- disk scrub or switching to a different location on the network.

-------------------------------------------------------------------------------
-- Representation notes
-------------------------------------------------------------------------------

-- XXX we can use newtype over stream for buffers. That way we can implement
-- operations like length as a fold of length of all underlying buffers.
-- A single buffer could be a singleton stream and more than one buffers would
-- be a stream of buffers.
--
-- Also, if a single buffer size is more than a threshold we can store it as a
-- linked list in the non-gc memory. This will allow unlimited size buffers to
-- be stored.
--
-- Unified Array + Stream:
-- We can use a "Array" as the unified stream structure. When we use a pure
-- cons we can increase the count of buffered elements in the stream, when we
-- use uncons we decrement the count. If the count goes beyond a threshold we
-- vectorize the buffered part. So if we are accessing an index at the end of
-- the stream and still want to hold on to the stream elements then we would be
-- buffering it by consing the elements and therefore automatically vectorizing
-- it. By consing we are joining an evaluated part with a potentially
-- unevaluated tail therefore strictizing the stream. When we uncons we are
-- actually taking out a vector (i.e. evaluated part, WHNF of course) from the
-- stream.

module Streamly.Array
    (
      Array (..)

    -- * Construction/Generation
    , nil
    , singleton
    , fromList
    , readHandleWith

    -- * Elimination/Folds
    , null
    , length
    , toList
    , toHandle
    )
where

import Control.Exception (assert)
import Control.Monad.IO.Class (MonadIO(..))
import Data.Functor.Identity (runIdentity)
import Data.Word (Word8)
import Foreign.C.String (CString)
import Foreign.C.Types (CSize(..))
import Foreign.ForeignPtr (withForeignPtr, touchForeignPtr)
import Foreign.ForeignPtr.Unsafe (unsafeForeignPtrToPtr)
import Foreign.Ptr (plusPtr, minusPtr, castPtr)
import Foreign.Storable (Storable(..))
import System.IO (Handle, hGetBufSome, hPutBuf)
import System.IO.Unsafe (unsafePerformIO)
import Text.Read (Lexeme(Ident), lexP, parens, prec, readPrec, readListPrec,
                  readListPrecDefault)
import Prelude hiding (length, null)
import qualified Prelude

import GHC.Base (Addr#, nullAddr#, realWorld#)
import GHC.ForeignPtr
    (ForeignPtr(..), mallocPlainForeignPtrBytes, newForeignPtr_)
import GHC.IO (IO(IO), unsafeDupablePerformIO)
import GHC.Ptr (Ptr(..))

import Streamly.SVar (adaptState, defState)
import Streamly.Streams.StreamK.Type (IsStream, mkStream)
import Streamly.Array.Types -- (Array(..), ByteArray, dangerousPerformIO)

-- import Streamly.Streams.Serial (SerialT)
-- import qualified Streamly.Prelude as S
import qualified Streamly.Foldl as FL
-- import qualified Streamly.Streams.StreamD.Type as D
import qualified Streamly.Streams.StreamD as D

-------------------------------------------------------------------------------
-- Nesting/Layers
-------------------------------------------------------------------------------

-- A stream of vectors can be grouped to create vectors of vectors i.e. a tree
-- of vectors. A tree of vectors can be concated to reduce the level of the
-- tree or turn it into a single vector.

--  When converting a whole stream to a single vector, we can keep adding new
--  levels to a vector tree, creating vectors of vectors so that we do not have
--  to keep reallocating and copying the old data to new buffers. We can later
--  reduce the levels by compacting the tree if we want to. The 'limit'
--  argument is to raise an exception if the total size exceeds this limit,
--  this is a safety catch so that we do not vectorize infinite streams and
--  then run out of memory.
--
-- We can keep group folding a stream until we get a singleton stream.

-------------------------------------------------------------------------------
-- Compact vectors
-------------------------------------------------------------------------------

{-
-- we can call these regroupXXX or reArrayXXX
--
-- Compact buffers in a stream such that each resulting buffer contains exactly
-- N elements.
compactN :: Int -> Int -> t m (Array a) -> t m (Array a)
compactN n vectors =

-- This can be useful if the input stream may "suspend" before generating
-- further output. So we can emit a vector early without waiting. It will emit
-- a vector of at least 1 element.
compactUpTo :: Int -> t m (Array a) -> t m (Array a)
compactUpTo hi vectors =

-- wait for minimum amount to be collected but don't wait for the upper limit
-- if the input stream suspends. But never go beyond the upper limit.
compactMinUpTo :: Int -> Int -> t m (Array a) -> t m (Array a)
compactMinUpTo lo hi vectors =

-- The buffer is emitted as soon as a complete marker sequence is detected. The
-- emitted buffer contains the sequence as suffix.
compactUpToMarker :: Array a -> t m (Array a) -> t m (Array a)
compactUpToMarker hi marker =

-- Buffer upto a max count or until timeout occurs. If timeout occurs without a
-- single element in the buffer it raises an exception.
compactUpToWithTimeout :: Int -> Int -> t m (Array a) -> t m (Array a)
compactUpToWithTimeout hi time =

-- Wait until min elements are collected irrespective of time. After collecting
-- minimum elements if timeout occurs return the buffer immediately else wait
-- upto timeout or max limit.
compactInRangeWithTimeout ::
    Int -> Int -> Int -> t m (Array a) -> t m (Array a)
compactInRangeWithTimeout lo hi time =

-- Compact the contiguous sequences into a single vector.
compactToReorder :: (a -> a -> Int) -> t m (Array a) -> t m (Array a)

-------------------------------------------------------------------------------
-- deCompact buffers
-------------------------------------------------------------------------------

-- split buffers into smaller buffers
-- deCompactBuffers :: Int -> Int -> t m Buffer -> t m Buffer
-- deCompactBuffers maxSize tolerance =

-------------------------------------------------------------------------------
-- Scatter/Gather IO
-------------------------------------------------------------------------------

-- When each IO opration has a significant system overhead, it may be more
-- efficient to do gather IO. But when the buffers are too small we may want to
-- copy multiple of them in a single buffer rather than setting up a gather
-- list. In that case, a gather list may have more overhead compared to just
-- copying. If the buffer is larger than a limit we may just keep a single
-- buffer in a gather list.
--
-- gatherBuffers :: Int -> t m Buffer -> t m GatherBuffer
-- gatherBuffers maxLimit bufs =
-}

-------------------------------------------------------------------------------
-- Construction
-------------------------------------------------------------------------------

-- XXX Use stream and toArray to create a vector.

-- Represent a null pointer for an empty vector
nullForeignPtr :: ForeignPtr a
nullForeignPtr = ForeignPtr nullAddr# (error "nullForeignPtr")

{-# INLINE nil #-}
nil :: Array a
nil = Array
    { aStart = nullForeignPtr
    , aEnd = Ptr nullAddr#
    , aBound = Ptr nullAddr#
    }

-- XXX should we use unsafePerformIO instead?
{-# INLINE singleton #-}
singleton :: forall a. Storable a => a -> Array a
singleton a =
    let !v = unsafeDupablePerformIO $ withNewArray 1 $ \p -> poke p a
    in (v {aEnd = aEnd v `plusPtr` (sizeOf (undefined :: a))})

{-# INLINABLE fromList #-}
fromList :: (Show a, Storable a) => [a] -> Array a
fromList xs = runIdentity $
    FL.foldl (FL.toArrayN (Prelude.length xs)) (D.fromStreamD (D.fromList xs))

-- | Read a 'ByteArray' from a file handle. If no data is available on the
-- handle it blocks until some data becomes available. If data is available
-- then it immediately returns that data without blocking. It reads a maximum
-- of up to the size requested.
{-# INLINE fromHandleSome #-}
fromHandleSome :: Int -> Handle -> IO ByteArray
fromHandleSome size h = do
    ptr <- mallocPlainForeignPtrBytes size
    withForeignPtr ptr $ \p -> do
        n <- hGetBufSome h p size
        let v = Array
                { aStart = ptr
                , aEnd   = p `plusPtr` n
                , aBound = p `plusPtr` size
                }
        -- XXX shrink only if the diff is significant
        shrinkToFit v

-- | @readHandleWith size h@ reads a stream of vectors from file handle @h@.
-- The maximum size of a single vector is limited to @size@.
{-# INLINE readHandleWith #-}
readHandleWith :: (IsStream t, MonadIO m) => Int -> Handle -> t m ByteArray
readHandleWith size h = go
  where
    -- XXX use cons/nil instead
    go = mkStream $ \_ yld sng _ -> do
        vec <- liftIO $ fromHandleSome size h
        if length vec < size
        then sng vec
        else yld vec go

-------------------------------------------------------------------------------
-- Elimination
-------------------------------------------------------------------------------

{-# INLINE length #-}
length :: forall a. Storable a => Array a -> Int
length Array{..} =
    let p = unsafeForeignPtrToPtr aStart
        aLen = aEnd `minusPtr` p
    in assert (aLen >= 0) (aLen `div` sizeOf (undefined :: a))

{-# INLINE null #-}
null :: Storable a => Array a -> Bool
null v = length v <= 0

-------------------------------------------------------------------------------
-- Elimination/folding
-------------------------------------------------------------------------------

{-# INLINABLE toList #-}
toList :: (Show a, Storable a) => Array a -> [a]
toList = runIdentity . D.toList . D.fromArray

-- XXX shall we have a ByteArray module for Word8 routines?

-- | Writing a stream to a file handle
{-# INLINE toHandle #-}
toHandle :: Handle -> ByteArray -> IO ()
toHandle _ v | null v = return ()
toHandle h v@Array{..} = withForeignPtr aStart $ \p -> hPutBuf h p (length v)


-------------------------------------------------------------------------------
-- Instances - XXX need to be moved along with the type
-------------------------------------------------------------------------------

instance (Storable a, Show a) => Show (Array a) where
    {-# INLINE showsPrec #-}
    showsPrec _ = shows . toList

instance (Storable a, Read a, Show a) => Read (Array a) where
    {-# INLINE readPrec #-}
    readPrec = do
          xs <- readPrec
          return (fromList xs)
    readListPrec = readListPrecDefault

-------------------------------------------------------------------------------
-- Buffer streams into vectors
-------------------------------------------------------------------------------

{-
data ToArrayState a =
      BufAlloc
    | BufWrite (ForeignPtr a) (Ptr a) (Ptr a)
    | BufStop

-- XXX we should never have zero sized chunks if we want to use "null" on a
-- stream of buffers to mean that the stream itself is null.
--
-- XXX use the grouped fold to do this. we need to check the performance
-- though.
--
-- | Group a stream into vectors on n elements each.
{-# INLINE toArrayStreamD #-}
toArrayStreamD
    :: forall m a.
       (Monad m, Storable a)
    => Int -> D.Stream m a -> D.Stream m (Array a)
toArrayStreamD n (D.Stream step state) =
    D.Stream step' (state, BufAlloc)

    where

    size = n * sizeOf (undefined :: a)

    {-# INLINE_LATE step' #-}
    step' _ (st, BufAlloc) =
        let !res = unsafePerformIO $ do
                fptr <- mallocPlainForeignPtrBytes size
                let p = unsafeForeignPtrToPtr fptr
                return $ D.Skip $ (st, BufWrite fptr p (p `plusPtr` n))
        in return res

    step' _ (st, BufWrite fptr cur end) | cur == end =
        return $ D.Yield (Array {vPtr = fptr, vLen = n, vSize = size})
                         (st, BufAlloc)

    step' gst (st, BufWrite fptr cur end) = do
        res <- step (adaptState gst) st
        return $ case res of
            D.Yield x s ->
                let !r = dangerousPerformIO $ do
                            poke cur x
                            -- XXX do we need a touch here?
                            return $ D.Skip
                                (s, BufWrite fptr (cur `plusPtr` 1) end)
                in r
            D.Skip s -> D.Skip (s, BufWrite fptr cur end)
            D.Stop ->
                -- XXX resizePtr the buffer
                D.Yield (Array { vPtr = fptr
                                , vLen = n + (cur `minusPtr` end)
                                , vSize = size})
                        (st, BufStop)

    step' _ (_, BufStop) = return D.Stop
    -}
