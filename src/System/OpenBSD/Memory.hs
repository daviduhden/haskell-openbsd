{- |
Module      : System.OpenBSD.Memory
Description : OpenBSD memory-protection and secure-memory helpers

OpenBSD's memory-handling extensions:

* @mimmutable(2)@: permanently forbid future changes to the
  protection or mapping of a memory region;
* @explicit_bzero(3)@ and @freezero(3)@: securely erase
  native-memory regions;
* @timingsafe_bcmp(3)@ and @timingsafe_memcmp(3)@:
  constant-time byte-string comparison.

Haskell values are garbage-collected, may be copied, and cannot be
reliably erased in place, so the erasure functions operate on
explicitly allocated native memory ('Foreign.Ptr.Ptr') and make no
promises about arbitrary immutable Haskell values.
'immutableMemory' likewise applies only to explicit native memory:
freezing pages that belong to the runtime, the garbage collector or
a @malloc(3)@ arena can permanently break the memory manager that
owns them.  The constant-time comparisons operate on
'Data.ByteString.ByteString' buffers and are the recommended
interfaces for comparing secrets such as hashes and MACs; do not
reimplement them with an early-exiting Haskell comparison.
-}
module System.OpenBSD.Memory (
    -- * Making memory permanently immutable
    immutableMemory,

    -- * Secure erasure of native memory
    explicitBzero,
    freeZero,

    -- * Constant-time comparison
    timingSafeEqual,
    timingSafeCompare,
) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.Ptr (Ptr, castPtr)
import System.OpenBSD.Internal (
    c_explicit_bzero,
    c_freezero,
    c_mimmutable,
    c_timingsafe_bcmp,
    c_timingsafe_memcmp,
 )

{- | Permanently forbid future changes to the protection or mapping
of a native memory region, as @mimmutable(2)@.

The region starting at @addr@ with the given length is marked
immutable: most subsequent @mprotect(2)@, @munmap(2)@, @madvise(2)@,
@msync(2)@, @mmap(2)@ and @minherit(2)@ operations on it fail with
@EPERM@ (unmapping is the core guarantee).  Reads and writes to the
memory itself remain allowed; the mechanism protects the /mapping/,
not the contents.  The change is permanent.

The kernel aligns the range /outward/ to whole pages, rounding
@addr@ down and the length up, so every page that overlaps the
region becomes immutable.  @addr@ must therefore point into a
dedicated native mapping (for example one created with @mmap(2)@)
that will never be returned to an allocator: freezing a page that
belongs to the GHC heap, to a 'Data.ByteString.ByteString' buffer or
to a @malloc(3)@ arena can permanently prevent the runtime or the
allocator from @mprotect(2)@ing or @munmap(2)@ing memory it owns.
This binding takes a raw pointer and length rather than a bytestring
precisely so that this requirement cannot be overlooked.

A negative length is rejected and a zero length is a no-op.  Allowed
under the @stdio@ pledge promise.  An invalid range fails with the
native @EINVAL@.
-}
immutableMemory :: Ptr a -> Int -> IO ()
immutableMemory addr len
    | len < 0 = ioError (userError "immutableMemory: negative length")
    | len == 0 = pure ()
    | otherwise =
        throwErrnoIfMinus1_ "mimmutable" $
            c_mimmutable (castPtr addr) (fromIntegral len)

{- | Securely overwrite a native-memory region with zeroes, as
@explicit_bzero(3)@.

Unlike an ordinary @memset@, the write is not optimized away, so
the region cannot be recovered from memory afterward.  Operates on
explicitly allocated native memory; a negative length is rejected.
It makes no claims about Haskell values that the garbage collector
may have copied elsewhere.
-}
explicitBzero :: Ptr a -> Int -> IO ()
explicitBzero buffer len
    | len < 0 = ioError (userError "explicitBzero: negative length")
    | otherwise = c_explicit_bzero (castPtr buffer) (fromIntegral len)

{- | Zero and release a @malloc(3)@-allocated region, as
@freezero(3)@.

The region of the given length (which must match the allocation)
is overwritten with zeroes and then freed.  Ownership transfers to
this function: the pointer must not be used afterwards.  A
negative length is rejected.
-}
freeZero :: Ptr a -> Int -> IO ()
freeZero buffer len
    | len < 0 = ioError (userError "freeZero: negative length")
    | otherwise = c_freezero (castPtr buffer) (fromIntegral len)

{- | Constant-time equality of two byte buffers, as
@timingsafe_bcmp(3)@.

The comparison time depends only on the length of the shorter
input, never on where the first difference occurs, so it is
suitable for comparing secrets (hashes, MACs, keys).  Buffers of
different lengths are simply unequal (a length is not secret
material).  The native function performs the work; this wrapper
never short-circuits the comparison in Haskell.
-}
timingSafeEqual :: ByteString -> ByteString -> IO Bool
timingSafeEqual a b
    | BS.length a /= BS.length b = pure False
    | otherwise =
        BS.useAsCStringLen a $ \(bufferA, len) ->
            BS.useAsCStringLen b $ \(bufferB, _) ->
                (== 0)
                    <$> c_timingsafe_bcmp
                        (castPtr bufferA)
                        (castPtr bufferB)
                        (fromIntegral len)

{- | Constant-time lexicographic comparison of two byte buffers, as
@timingsafe_memcmp(3)@.

Compares the common prefix of both buffers in constant time and
breaks ties by length (the shorter buffer sorts first), matching
the native comparison semantics.  Suitable for ordering secret
material without leaking where the first difference occurs.
-}
timingSafeCompare :: ByteString -> ByteString -> IO Ordering
timingSafeCompare a b = do
    let lenA = BS.length a
        lenB = BS.length b
        common = min lenA lenB
    result <- BS.useAsCStringLen a $ \(bufferA, _) ->
        BS.useAsCStringLen b $ \(bufferB, _) ->
            c_timingsafe_memcmp
                (castPtr bufferA)
                (castPtr bufferB)
                (fromIntegral common)
    pure
        ( case compare result 0 of
            EQ -> compare lenA lenB
            other -> other
        )
