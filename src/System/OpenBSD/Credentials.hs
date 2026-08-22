-- |
-- Module      : System.OpenBSD.Credentials
-- Description : Process and peer credential queries
--
-- Two credential-related OpenBSD interfaces:
--
-- * @issetugid(2)@ reports whether the current process image was
--   tainted by set-user-ID or set-group-ID execution.
--
-- * @getpeereid(3)@ returns the effective user and group IDs of the
--   peer connected to a local Unix-domain socket.
--
-- Neither is an authorization mechanism by itself; they supply facts
-- that an application can use as part of its own authorization
-- decisions.
module System.OpenBSD.Credentials
    ( -- * Set-ID execution state
      isSetugid
      -- * Unix-domain peer credentials
    , getPeerCredentials
      -- * Types re-exported for convenience
    , Fd
    , UserID
    , GroupID
    ) where

import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Storable (peek)
import System.OpenBSD.Internal (c_getpeereid, c_issetugid)
import System.Posix.Types (Fd, GroupID, UserID)

-- | Report whether the current process image was tainted by
-- set-user-ID or set-group-ID execution, as @issetugid(2)@.
--
-- This is /not/ a comparison of the current real and effective
-- UIDs\/GIDs, and it is /not/ affected by calls that change the
-- IDs.  It reflects whether the process was created as the result of
-- an @execve(2)@ whose file had the setuid\/setgid bits set, or whose
-- real, effective or saved UIDs\/GIDs were mismatched.  A @fork(2)@
-- inherits the same status.  Library code uses it to decide whether
-- inherited state (such as environment variables naming files) may be
-- trusted.
--
-- Allowed under the @stdio@ pledge promise.
isSetugid :: IO Bool
isSetugid = (/= 0) <$> c_issetugid

-- | Return the effective user ID and group ID of the peer connected
-- to a local Unix-domain socket, as @getpeereid(3)@.
--
-- The descriptor must refer to a connected Unix-domain
-- @SOCK_STREAM@ or @SOCK_SEQPACKET@ socket.  This is the credential
-- source for Unix-domain servers that want to know who their clients
-- are; the returned values are peer credentials, not an
-- authentication result by themselves.  Fails with the native error
-- (for example @EBADF@ for an invalid descriptor, @ENOTSOCK@ for a
-- regular file, @EOPNOTSUPP@ for a non-Unix-domain socket,
-- @ENOTCONN@ for an unconnected socket).
--
-- Not permitted once the process has called @pledge(2)@: no promise
-- covers this call, so it must be used before pledging.
getPeerCredentials :: Fd -> IO (UserID, GroupID)
getPeerCredentials sock =
    alloca $ \peuid ->
    alloca $ \pegid -> do
        throwErrnoIfMinus1_ "getpeereid" $
            c_getpeereid sock peuid pegid
        (,) <$> peek peuid <*> peek pegid
