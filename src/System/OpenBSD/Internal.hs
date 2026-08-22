{-# LANGUAGE CPP #-}

-- |
-- Module      : System.OpenBSD.Internal
-- Description : Raw FFI boundary for the openbsd package
--
-- This module is internal.  It contains the raw @foreign import@
-- declarations, the unsupported-platform guard, and the small
-- marshalling helpers shared by the public modules.  Nothing in here
-- is exported by the package.
--
-- All imports are @unsafe@: every function here is a short,
-- non-blocking libc wrapper that performs no callbacks and cannot
-- re-enter the RTS, so the faster @unsafe@ calling convention is
-- appropriate (the word \"unsafe\" refers to the FFI convention, not
-- to security).  None of them can throw Haskell exceptions while a
-- pointer argument is live.
--
-- The 'c_hsSetproctitle'\/'c_hsResetproctitle' pair wraps the tiny C
-- shim in @cbits\/openbsd.c@; see there for the rationale.
module System.OpenBSD.Internal
    ( c_pledge
    , c_unveil
    , c_setresuid
    , c_setresgid
    , c_getresuid
    , c_getresgid
    , c_initgroups
    , c_chroot
    , c_issetugid
    , c_getpeereid
    , c_arc4random
    , c_arc4random_buf
    , c_arc4random_uniform
    , c_hsSetproctitle
    , c_hsResetproctitle
    , c_closefrom
    , c_getdtablecount
    , c_getrtable
    , c_setrtable
    , c_getentropy
    , c_mimmutable
    , c_explicit_bzero
    , c_freezero
    , c_timingsafe_bcmp
    , c_timingsafe_memcmp
    , c_getprogname
    , c_setprogname
    , c_crypt_checkpass
    , c_crypt_newhash
    , c_bcrypt_pbkdf
    , checkNoNul
    , withMaybeCString
    ) where

import Data.Word (Word32)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CChar, CInt(..), CSize(..))
import Foreign.Ptr (Ptr, nullPtr)
import System.Posix.Types (CGid(..), CUid(..), Fd(..))

#if defined(openbsd_HOST_OS)

foreign import ccall unsafe "unistd.h pledge"
    c_pledge :: CString -> CString -> IO CInt

foreign import ccall unsafe "unistd.h unveil"
    c_unveil :: CString -> CString -> IO CInt

foreign import ccall unsafe "unistd.h setresuid"
    c_setresuid :: CUid -> CUid -> CUid -> IO CInt

foreign import ccall unsafe "unistd.h setresgid"
    c_setresgid :: CGid -> CGid -> CGid -> IO CInt

foreign import ccall unsafe "unistd.h getresuid"
    c_getresuid :: Ptr CUid -> Ptr CUid -> Ptr CUid -> IO CInt

foreign import ccall unsafe "unistd.h getresgid"
    c_getresgid :: Ptr CGid -> Ptr CGid -> Ptr CGid -> IO CInt

foreign import ccall unsafe "grp.h initgroups"
    c_initgroups :: CString -> CGid -> IO CInt

foreign import ccall unsafe "unistd.h chroot"
    c_chroot :: CString -> IO CInt

foreign import ccall unsafe "unistd.h issetugid"
    c_issetugid :: IO CInt

foreign import ccall unsafe "sys/socket.h getpeereid"
    c_getpeereid :: Fd -> Ptr CUid -> Ptr CGid -> IO CInt

foreign import ccall unsafe "stdlib.h arc4random"
    c_arc4random :: IO Word32

foreign import ccall unsafe "stdlib.h arc4random_buf"
    c_arc4random_buf :: Ptr () -> CSize -> IO ()

foreign import ccall unsafe "stdlib.h arc4random_uniform"
    c_arc4random_uniform :: Word32 -> IO Word32

foreign import ccall unsafe "hs_setproctitle"
    c_hsSetproctitle :: CString -> IO ()

foreign import ccall unsafe "hs_resetproctitle"
    c_hsResetproctitle :: IO ()

foreign import ccall unsafe "unistd.h closefrom"
    c_closefrom :: CInt -> IO ()

foreign import ccall unsafe "unistd.h getdtablecount"
    c_getdtablecount :: IO CInt

foreign import ccall unsafe "unistd.h getrtable"
    c_getrtable :: IO CInt

foreign import ccall unsafe "unistd.h setrtable"
    c_setrtable :: CInt -> IO CInt

foreign import ccall unsafe "unistd.h getentropy"
    c_getentropy :: Ptr () -> CSize -> IO CInt

foreign import ccall unsafe "unistd.h mimmutable"
    c_mimmutable :: Ptr () -> CSize -> IO CInt

foreign import ccall unsafe "string.h explicit_bzero"
    c_explicit_bzero :: Ptr () -> CSize -> IO ()

foreign import ccall unsafe "stdlib.h freezero"
    c_freezero :: Ptr () -> CSize -> IO ()

foreign import ccall unsafe "string.h timingsafe_bcmp"
    c_timingsafe_bcmp :: Ptr () -> Ptr () -> CSize -> IO CInt

foreign import ccall unsafe "string.h timingsafe_memcmp"
    c_timingsafe_memcmp :: Ptr () -> Ptr () -> CSize -> IO CInt

foreign import ccall unsafe "stdlib.h getprogname"
    c_getprogname :: IO CString

foreign import ccall unsafe "stdlib.h setprogname"
    c_setprogname :: CString -> IO ()

foreign import ccall unsafe "unistd.h crypt_checkpass"
    c_crypt_checkpass :: CString -> CString -> IO CInt

foreign import ccall unsafe "unistd.h crypt_newhash"
    c_crypt_newhash :: CString -> CString -> Ptr CChar -> CSize -> IO CInt

foreign import ccall unsafe "util.h bcrypt_pbkdf"
    c_bcrypt_pbkdf :: Ptr () -> CSize -> Ptr () -> CSize -> Ptr () -> CSize
                  -> Word32 -> IO CInt

#else

#error "haskell-openbsd requires OpenBSD: pledge(2), unveil(2), chroot(2), issetugid(2), getpeereid(3), setproctitle(3), arc4random(3) and the privilege-dropping interfaces are OpenBSD-only."

#endif

-- | Reject strings that contain a @NUL@ byte before they reach any C
-- string conversion.  A @NUL@ would silently truncate the string at
-- the libc boundary, so accepting it here could make the kernel see a
-- different (shorter) value than the caller supplied.  Raises a
-- 'System.IO.Error.userError' with a message naming the offending
-- input.
checkNoNul :: String -> String -> IO ()
checkNoNul what input
    | '\0' `elem` input = ioError (userError (what ++ ": input contains a NUL byte: " ++ show input))
    | otherwise = return ()

-- | Like 'withCString', but 'Nothing' is passed to the action as
-- @NULL@ instead of allocating a buffer.
withMaybeCString :: Maybe String -> (CString -> IO a) -> IO a
withMaybeCString Nothing  action = action nullPtr
withMaybeCString (Just s) action = withCString s action
