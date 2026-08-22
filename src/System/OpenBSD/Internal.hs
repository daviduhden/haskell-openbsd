{-# LANGUAGE CPP #-}

-- |
-- Module      : System.OpenBSD.Internal
-- Description : Raw FFI boundary for the openbsd package
--
-- This module is internal.  It contains the raw @foreign import@
-- declarations, the unsupported-platform guard, and the two small
-- marshalling helpers shared by the public modules.  Nothing in here
-- is exported by the package.
--
-- All imports are @unsafe@: every function here is a short,
-- non-blocking libc wrapper that performs no callbacks and cannot
-- re-enter the RTS, so the faster @unsafe@ calling convention is
-- appropriate (the word \"unsafe\" refers to the FFI convention, not
-- to security).  None of them can throw Haskell exceptions while a
-- pointer argument is live.
module System.OpenBSD.Internal
    ( c_pledge
    , c_unveil
    , c_setresuid
    , c_setresgid
    , c_getresuid
    , c_getresgid
    , c_initgroups
    , checkNoNul
    , withMaybeCString
    ) where

import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt(..))
import Foreign.Ptr (Ptr, nullPtr)
import System.Posix.Types (CGid(..), CUid(..))

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

#else

#error "haskell-openbsd requires OpenBSD: pledge(2), unveil(2) and the privilege-dropping interfaces are OpenBSD-only."

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
