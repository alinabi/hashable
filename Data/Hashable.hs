{-# LANGUAGE BangPatterns, CPP, ForeignFunctionInterface, MagicHash,
             UnliftedFFITypes, FlexibleInstances, UndecidableInstances,
             OverlappingInstances #-}

------------------------------------------------------------------------
-- |
-- Module      :  Data.Hash
-- Copyright   :  (c) Milan Straka 2010
--                (c) Johan Tibell 2011
--                (c) Bryan O'Sullivan 2011
-- License     :  BSD-style
-- Maintainer  :  johan.tibell@gmail.com
-- Stability   :  provisional
-- Portability :  portable
--
-- This module defines a class, 'Hashable', for types that can be
-- converted to a hash value.  This class exists for the benefit of
-- hashing-based data structures.  The module provides instances for
-- basic types and a way to combine hash values.
--
-- The 'hash' function should be as collision-free as possible, which
-- means that the 'hash' function must map the inputs to the hash
-- values as evenly as possible.

module Data.Hashable
    (
      -- * Computing hash values
      Hashable(..)

      -- * Creating new instances
      -- $blocks
    , hashPtr
    , hashPtrWithSalt
#if defined(__GLASGOW_HASKELL__)
    , hashByteArray
    , hashByteArrayWithSalt
#endif
    , combine
    ) where

import Data.Bits (bitSize, shiftL, shiftR, xor)
import Data.Int (Int8, Int16, Int32, Int64)
import Data.Word (Word, Word8, Word16, Word32, Word64)
import Data.List (foldl')
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as B
import qualified Data.ByteString.Unsafe as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Internal as BL
import qualified Data.Text as T
import qualified Data.Text.Array as TA
import qualified Data.Text.Internal as T
import qualified Data.Text.Lazy as LT
import Foreign.C (CLong, CString)
import Foreign.Ptr (Ptr, castPtr)
import Data.Binary (Binary, encode)

#if defined(__GLASGOW_HASKELL__)
import Foreign.C.Types (CInt)
import GHC.Base (ByteArray#)
import GHC.Conc (ThreadId(..))
import GHC.Prim (ThreadId#)
#else
import Control.Concurrent (ThreadId)
#endif

------------------------------------------------------------------------
-- * Computing hash values

-- | A default salt used in the default implementation of
-- 'hashWithSalt'.
defaultSalt :: Int
defaultSalt = 17
{-# INLINE defaultSalt #-}

-- | The class of types that can be converted to a hash value.
--
-- Minimal implementation: 'hash' or 'hashWithSalt'.
class Hashable a where
    -- | Return a hash value for the argument.
    --
    -- The general contract of 'hash' is:
    --
    --  * This integer need not remain consistent from one execution
    --    of an application to another execution of the same
    --    application.
    --
    --  * If two values are equal according to the '==' method, then
    --    applying the 'hash' method on each of the two values must
    --    produce the same integer result.
    --
    --  * It is /not/ required that if two values are unequal
    --    according to the '==' method, then applying the 'hash'
    --    method on each of the two values must produce distinct
    --    integer results.  However, the programmer should be aware
    --    that producing distinct integer results for unequal values
    --    may improve the performance of hashing-based data
    --    structures.
    hash :: a -> Int
    hash = hashWithSalt defaultSalt

    -- | Return a hash value for the argument, using the given salt.
    --
    -- This method can be used to compute different hash values for
    -- the same input by providing a different salt in each
    -- application of the method.
    --
    -- The contract for 'hashWithSalt' is the same as for 'hash', with
    -- the additional requirement that any instance that defines
    -- 'hashWithSalt' must make use of the salt in its implementation.
    hashWithSalt :: Int -> a -> Int
    hashWithSalt salt x = salt `combine` hash x

instance Hashable () where hash _ = 0

instance Hashable Bool where hash x = case x of { True -> 1; False -> 0 }

instance Hashable Int where hash = id
instance Hashable Int8 where hash = fromIntegral
instance Hashable Int16 where hash = fromIntegral
instance Hashable Int32 where hash = fromIntegral
instance Hashable Int64 where
    hash n
        | bitSize (undefined :: Int) == 64 = fromIntegral n
        | otherwise = fromIntegral (fromIntegral n `xor`
                                   (fromIntegral n `shiftR` 32 :: Word64))

instance Hashable Word where hash = fromIntegral
instance Hashable Word8 where hash = fromIntegral
instance Hashable Word16 where hash = fromIntegral
instance Hashable Word32 where hash = fromIntegral
instance Hashable Word64 where
    hash n
        | bitSize (undefined :: Int) == 64 = fromIntegral n
        | otherwise = fromIntegral (n `xor` (n `shiftR` 32))

instance Hashable Char where hash = fromEnum

instance Hashable a => Hashable (Maybe a) where
    hash Nothing = 0
    hash (Just a) = 1 `combine` hash a

instance (Hashable a, Hashable b) => Hashable (Either a b) where
    hash (Left a)  = 0 `combine` hash a
    hash (Right b) = 1 `combine` hash b

instance (Hashable a1, Hashable a2) => Hashable (a1, a2) where
    hash (a1, a2) = defaultSalt `combine` hash a1 `combine` hash a2

instance (Hashable a1, Hashable a2, Hashable a3) => Hashable (a1, a2, a3) where
    hash (a1, a2, a3) = defaultSalt `combine` hash a1 `combine` hash a2
                        `combine` hash a3

instance (Hashable a1, Hashable a2, Hashable a3, Hashable a4) =>
         Hashable (a1, a2, a3, a4) where
    hash (a1, a2, a3, a4) = defaultSalt `combine` hash a1 `combine` hash a2
                            `combine` hash a3 `combine` hash a4

instance (Hashable a1, Hashable a2, Hashable a3, Hashable a4, Hashable a5)
      => Hashable (a1, a2, a3, a4, a5) where
    hash (a1, a2, a3, a4, a5) =
        defaultSalt `combine` hash a1 `combine` hash a2 `combine` hash a3
        `combine` hash a4 `combine` hash a5

instance (Hashable a1, Hashable a2, Hashable a3, Hashable a4, Hashable a5,
          Hashable a6) => Hashable (a1, a2, a3, a4, a5, a6) where
    hash (a1, a2, a3, a4, a5, a6) =
        defaultSalt `combine` hash a1 `combine` hash a2 `combine` hash a3
        `combine` hash a4 `combine` hash a5 `combine` hash a6

instance (Hashable a1, Hashable a2, Hashable a3, Hashable a4, Hashable a5,
          Hashable a6, Hashable a7) =>
         Hashable (a1, a2, a3, a4, a5, a6, a7) where
    hash (a1, a2, a3, a4, a5, a6, a7) =
        defaultSalt `combine` hash a1 `combine` hash a2 `combine` hash a3
        `combine` hash a4 `combine` hash a5 `combine` hash a6 `combine` hash a7

-- | Default salt for hashing string like types.
stringSalt :: Int
stringSalt = 5381

instance Hashable a => Hashable [a] where
    {-# SPECIALIZE instance Hashable [Char] #-}
    hash = foldl' hashAndCombine stringSalt
    hashWithSalt = foldl' hashAndCombine

-- | Compute the hash of a ThreadId.  For GHC, we happen to know a
-- trick to make this fast.
hashThreadId :: ThreadId -> Int
{-# INLINE hashThreadId #-}
#if defined(__GLASGOW_HASKELL__)
hashThreadId (ThreadId t) = hash (fromIntegral (getThreadId t) :: Int)
foreign import ccall unsafe "rts_getThreadId" getThreadId :: ThreadId# -> CInt
#else
hashThreadId = hash . show
#endif

instance Hashable ThreadId where
    hash = hashThreadId
    {-# INLINE hash #-}

hashAndCombine :: Hashable h => Int -> h -> Int
hashAndCombine acc h = acc `combine` hash h

instance Hashable B.ByteString where
    hash bs = B.inlinePerformIO $
              B.unsafeUseAsCStringLen bs $ \(p, len) ->
              hashPtr p (fromIntegral len)

    hashWithSalt salt bs = B.inlinePerformIO $
                           B.unsafeUseAsCStringLen bs $ \(p, len) ->
                           hashPtrWithSalt p (fromIntegral len) salt

instance Hashable BL.ByteString where
    hash = BL.foldlChunks hashWithSalt stringSalt
    hashWithSalt = BL.foldlChunks hashWithSalt

instance Hashable T.Text where
    hash (T.Text arr off len) = hashByteArray (TA.aBA arr)
                                (off `shiftL` 1) (len `shiftL` 1)

    hashWithSalt salt (T.Text arr off len) =
        hashByteArrayWithSalt (TA.aBA arr) (off `shiftL` 1) (len `shiftL` 1)
        salt

instance Hashable LT.Text where
    hash = LT.foldlChunks hashWithSalt stringSalt
    hashWithSalt = LT.foldlChunks hashWithSalt

instance Binary a => Hashable a where
    hash = hash . encode
    hashWithSalt s = hashWithSalt s . encode

------------------------------------------------------------------------
-- * Creating new instances

-- $blocks
--
-- The functions below can be used when creating new instances of
-- 'Hashable'.  For example, the 'hash' method for many string-like
-- types can be defined in terms of either 'hashPtr' or
-- 'hashByteArray'.  Here's how you could implement an instance for
-- the 'B.ByteString' data type, from the @bytestring@ package:
--
-- > import qualified Data.ByteString as B
-- > import qualified Data.ByteString.Internal as B
-- > import qualified Data.ByteString.Unsafe as B
-- > import Data.Hashable
-- > import Foreign.Ptr (castPtr)
-- >
-- > instance Hashable B.ByteString where
-- >     hash bs = B.inlinePerformIO $
-- >               B.unsafeUseAsCStringLen bs $ \ (p, len) ->
-- >               hashPtr p (fromIntegral len)
--
-- The 'combine' function can be used to implement 'Hashable'
-- instances for data types with more than one field, using this
-- recipe:
--
-- > instance (Hashable a, Hashable b) => Hashable (Foo a b) where
-- >     hash (Foo a b) = 17 `combine` hash a `combine` hash b
--
-- A nonzero seed is used so the hash value will be affected by
-- initial fields whose hash value is zero.  If no seed was provided,
-- the overall hash value would be unaffected by any such initial
-- fields, which could increase collisions.  The value 17 is
-- arbitrary.

-- | Compute a hash value for the content of this pointer.
hashPtr :: Ptr a      -- ^ pointer to the data to hash
        -> Int        -- ^ length, in bytes
        -> IO Int     -- ^ hash value
hashPtr p len = hashPtrWithSalt p len stringSalt

-- | Compute a hash value for the content of this pointer, using an
-- initial salt.
--
-- This function can for example be used to hash non-contiguous
-- segments of memory as if they were one contiguous segment, by using
-- the output of one hash as the salt for the next.
hashPtrWithSalt :: Ptr a   -- ^ pointer to the data to hash
                -> Int     -- ^ length, in bytes
                -> Int     -- ^ salt
                -> IO Int  -- ^ hash value
hashPtrWithSalt p len salt =
    fromIntegral `fmap` hashCString (castPtr p) (fromIntegral len)
    (fromIntegral salt)

foreign import ccall unsafe "djb_hash" hashCString
    :: CString -> CLong -> CLong -> IO CLong

#if defined(__GLASGOW_HASKELL__)
-- | Compute a hash value for the content of this 'ByteArray#',
-- beginning at the specified offset, using specified number of bytes.
-- Availability: GHC.
hashByteArray :: ByteArray#  -- ^ data to hash
              -> Int         -- ^ offset, in bytes
              -> Int         -- ^ length, in bytes
              -> Int         -- ^ hash value
hashByteArray ba0 off len = hashByteArrayWithSalt ba0 off len stringSalt
{-# INLINE hashByteArray #-}

-- | Compute a hash value for the content of this 'ByteArray#', using
-- an initial salt.
--
-- This function can for example be used to hash non-contiguous
-- segments of memory as if they were one contiguous segment, by using
-- the output of one hash as the salt for the next.
--
-- Availability: GHC.
hashByteArrayWithSalt
    :: ByteArray#  -- ^ data to hash
    -> Int         -- ^ offset, in bytes
    -> Int         -- ^ length, in bytes
    -> Int         -- ^ salt
    -> Int         -- ^ hash value
hashByteArrayWithSalt ba !off !len !h0 =
    fromIntegral $ c_hashByteArray ba (fromIntegral off) (fromIntegral len)
    (fromIntegral h0)

foreign import ccall unsafe "djb_hash_offset" c_hashByteArray
    :: ByteArray# -> CLong -> CLong -> CLong -> CLong
#endif

-- | Combine two given hash values.  'combine' has zero as a left
-- identity.
combine :: Int -> Int -> Int
combine h1 h2 = (h1 + h1 `shiftL` 5) `xor` h2
