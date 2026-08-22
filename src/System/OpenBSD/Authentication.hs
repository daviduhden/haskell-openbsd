-- |
-- Module      : System.OpenBSD.Authentication
-- Description : OpenBSD password hashing and key derivation
--
-- OpenBSD's password-hashing facilities:
--
-- * @crypt_checkpass(3)@: verify a password against a hash;
-- * @crypt_newhash(3)@: create a new salted password hash;
-- * @bcrypt_pbkdf(3)@: bcrypt-based password key derivation.
--
-- These call OpenBSD's implementations directly; no cryptographic
-- code lives in this package.
--
-- Passwords are passed as 'Data.ByteString.ByteString' (bytes, not
-- 'String') and are never logged or embedded in exceptions.  Two
-- unavoidable limitations of the garbage-collected runtime apply:
-- password buffers cannot be guaranteed to be erased in place (use
-- 'System.OpenBSD.Memory.explicitBzero' on explicit native buffers
-- if that matters), and the comparison itself is performed by the
-- native constant-time implementation.
module System.OpenBSD.Authentication
    ( -- * Password hashes
      cryptCheckpass
    , cryptNewhash
      -- * Key derivation
    , bcryptPbkdf
    ) where

import Control.Monad (when)
import Data.ByteString (ByteString, empty, packCString, packCStringLen)
import qualified Data.ByteString as BS
import Data.Word (Word32)
import Foreign.C.Error (eACCES, getErrno, throwErrno,
                        throwErrnoIfMinus1_)
import Foreign.C.String (withCString)
import Foreign.Marshal.Alloc (allocaBytes, free, mallocBytes)
import Foreign.Ptr (castPtr)
import System.OpenBSD.Internal (c_bcrypt_pbkdf, c_crypt_checkpass,
                                c_crypt_newhash, checkNoNul)

-- | Verify a password against a hash, as @crypt_checkpass(3)@.
--
-- Returns 'True' when the password matches the hash.  An invalid
-- hash or a non-matching password yields 'False' (the native
-- @EACCES@ case); genuine errors such as @ENOMEM@ are raised.  Both
-- the empty password and the empty hash being empty is documented as
-- a successful match by the native function.
--
-- Passwords and hashes cross the FFI boundary as C strings: embedded
-- @NUL@ bytes are rejected rather than silently truncated.
cryptCheckpass :: ByteString -> ByteString -> IO Bool
cryptCheckpass password hash = do
    checkBytesNoNul "cryptCheckpass" password
    checkBytesNoNul "cryptCheckpass" hash
    BS.useAsCString password $ \cPassword ->
        BS.useAsCString hash $ \cHash -> do
            result <- c_crypt_checkpass cPassword cHash
            if result == 0
                then pure True
                else do
                    errno <- getErrno
                    if errno == eACCES
                        then pure False
                        else throwErrno "crypt_checkpass"

-- | Create a new salted password hash, as @crypt_newhash(3)@.
--
-- The preference string selects the algorithm and parameters, for
-- example @\"bcrypt,4\"@ (rounds between 4 and 31) or
-- @\"bcrypt,a\"@ (automatically chosen rounds).  An unsupported
-- preference fails with the native @EINVAL@.  The password and the
-- preference must not contain embedded @NUL@ bytes.
cryptNewhash :: ByteString -> String -> IO ByteString
cryptNewhash password pref = do
    checkBytesNoNul "cryptNewhash" password
    checkNoNul "cryptNewhash" pref
    BS.useAsCString password $ \cPassword ->
        withCString pref $ \cPref ->
            allocaBytes passwordLen $ \buffer -> do
                throwErrnoIfMinus1_ "crypt_newhash" $
                    c_crypt_newhash cPassword cPref buffer
                        (fromIntegral passwordLen)
                packCString (castPtr buffer)
  where
    -- _PASSWORD_LEN, as required by crypt_newhash(3).
    passwordLen = 128

-- | Derive a key from a password and salt, as @bcrypt_pbkdf(3)@.
--
-- The output length is given explicitly; the salt should be random
-- material such as 'System.OpenBSD.Random.arc4RandomBytes' output.
-- Higher @rounds@ values make each attempt slower.  The derivation
-- is deterministic for identical inputs.
--
-- A negative output length is rejected; the native call reports
-- invalid arguments as a plain failure without a documented
-- @errno@.
bcryptPbkdf :: ByteString -> ByteString -> Word32 -> Int -> IO ByteString
bcryptPbkdf password salt rounds keyLen
    | keyLen < 0 = ioError (userError "bcryptPbkdf: negative key length")
    | keyLen == 0 = pure empty
    | otherwise = do
        keyBuffer <- mallocBytes keyLen
        result <- BS.useAsCStringLen password $ \(passPtr, passLen) ->
                  BS.useAsCStringLen salt $ \(saltPtr, saltLen) ->
                      c_bcrypt_pbkdf
                          (castPtr passPtr) (fromIntegral passLen)
                          (castPtr saltPtr) (fromIntegral saltLen)
                          keyBuffer (fromIntegral keyLen) rounds
        when (result /= 0) $ do
            free keyBuffer
            ioError (userError "bcrypt_pbkdf: invalid arguments")
        key <- packCStringLen (castPtr keyBuffer, keyLen)
        free keyBuffer
        pure key

-- | Reject embedded NUL bytes in secret byte strings before they
-- cross a C string boundary, where the native function would
-- silently see a truncated value.
checkBytesNoNul :: String -> ByteString -> IO ()
checkBytesNoNul what bytes =
    when (0 `BS.elem` bytes) $
        ioError (userError (what ++ ": input contains a NUL byte"))
