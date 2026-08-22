-- |
-- Module      : System.OpenBSD.Random
-- Description : OpenBSD arc4random(3)
--
-- Binding to OpenBSD's @arc4random(3)@ family: the system's
-- cryptographically strong pseudo-random number generator.
--
-- The API name is historical; the underlying implementation is
-- ChaCha20-based and is re-seeded from the kernel using
-- @getentropy(2)@ (and on @fork(2)@), and may be replaced again in
-- the future.  These functions can be used in almost all coding
-- environments, including within @chroot(2)@; under @pledge(2)@ the
-- @stdio@ promise is sufficient.
module System.OpenBSD.Random
    ( -- * Random values
      arc4Random
    , arc4RandomBytes
    , arc4RandomUniform
    ) where

import Data.ByteString (ByteString, empty, packCStringLen)
import Data.Word (Word32)
import Foreign.Marshal.Alloc (free, mallocBytes)
import Foreign.Ptr (castPtr)
import System.OpenBSD.Internal (c_arc4random, c_arc4random_buf,
                                c_arc4random_uniform)

-- | Return a single uniformly distributed 32-bit value, as
-- @arc4random()@.
arc4Random :: IO Word32
arc4Random = c_arc4random

-- | Fill a buffer of the given length with random bytes, as
-- @arc4random_buf()@.
--
-- The requested length is a Haskell 'Int': negative lengths are
-- rejected with an exception rather than being wrapped into a huge
-- unsigned @size_t@, and a zero length returns the empty bytestring
-- without calling into libc.  The temporary buffer obeys normal
-- Haskell allocation lifetimes and is released after the result is
-- copied out; no raw pointers are exposed.
arc4RandomBytes :: Int -> IO ByteString
arc4RandomBytes n
    | n < 0 = ioError (userError "arc4RandomBytes: negative length")
    | n == 0 = pure empty
    | otherwise = do
        buf <- mallocBytes n
        c_arc4random_buf (castPtr buf) (fromIntegral n)
        bytes <- packCStringLen (castPtr buf, n)
        free buf
        pure bytes

-- | Return a uniformly distributed 32-bit value strictly less than
-- @upperBound@, as @arc4random_uniform()@.
--
-- This is preferred over computing @arc4Random \`mod\` upperBound@:
-- the native function avoids modulo bias when the bound is not a
-- power of two.  The bound is passed through to the native function
-- unchanged: in particular @arc4random_uniform(0)@ and
-- @arc4random_uniform(1)@ both return @0@ on OpenBSD, and the bound
-- semantics of the current libc implementation apply verbatim.
arc4RandomUniform :: Word32 -> IO Word32
arc4RandomUniform = c_arc4random_uniform
