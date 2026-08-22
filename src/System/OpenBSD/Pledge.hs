{-# LANGUAGE CPP #-}

-- |
-- Module      : System.OpenBSD.Pledge
-- Description : OpenBSD pledge(2): restrict system operations
--
-- Binding to OpenBSD's @pledge(2)@ system call, which partitions the
-- POSIX feature set into subsystems (\"promises\") and aborts the
-- process with an uncatchable @SIGABRT@ if it uses operations outside
-- the declared set.
--
-- Calls to 'pledge' and friends are monotonic: each call may only
-- /reduce/ the set of available promises.  Attempts to increase
-- permissions fail with an @EPERM@ 'IOError' (unless the @error@
-- promise is active, in which case the increase is silently ignored).
module System.OpenBSD.Pledge
    ( -- * Promises
      Promise(..)
    , promiseName
      -- * Restricting the current process
    , pledge
      -- * Restricting future children (exec promises)
    , pledgeChild
    , pledgeBoth
      -- * Faithful interface
    , pledgeRaw
    ) where

import Control.Monad (when)
import Foreign.C.Error (throwErrno)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt)
import Foreign.Ptr (nullPtr)

#if defined(openbsd_HOST_OS)

foreign import ccall unsafe "unistd.h pledge"
    c_pledge :: CString -> CString -> IO CInt

#else

#error "The openbsd package requires OpenBSD: pledge(2) is an OpenBSD-only system call."

#endif

-- | A pledge promise, i.e. a subsystem of system operations that may be
-- requested in a call to @pledge(2)@.
--
-- This enumeration matches the promise list accepted by the kernel on
-- OpenBSD 7.9 and OpenBSD-current (see @sys\/kern\/kern_pledge.c@).
-- The @\"tmppath\"@ promise is deliberately /not/ represented: it was
-- removed from OpenBSD, and using it causes @pledge(2)@ to fail with
-- @EINVAL@.
data Promise
    = Audio      -- ^ audio(4) device @ioctl@ operations
    | Bpf        -- ^ bpf(4) statistics collection (@BIOCGSTATS@)
    | Chown      -- ^ change file owner or group
    | Cpath      -- ^ create or remove files
    | Disklabel  -- ^ disk label @ioctl@ operations
    | Dns        -- ^ DNS resolution
    | Dpath      -- ^ create special files (@mkfifo(2)@, @mknod(2)@)
    | Drm        -- ^ drm(4) @ioctl@ operations
    | Error      -- ^ return @ENOSYS@ on violations instead of being killed
    | Exec       -- ^ execute processes with @execve(2)@
    | Fattr      -- ^ change @struct stat@ fields of files
    | Flock      -- ^ file locking
    | Getpw      -- ^ read-only password database access
    | Id         -- ^ change process rights (@setuid@, @setgroups@, ...)
    | Inet       -- ^ @AF_INET@\/@AF_INET6@ socket operations
    | Mcast      -- ^ multicast socket operations (used with 'Inet')
    | Pf         -- ^ pf(4) @ioctl@ operations
    | Proc       -- ^ process relationship operations (@fork@, @kill@, ...)
    | ProtExec   -- ^ use @PROT_EXEC@ with @mmap(2)@\/@mprotect(2)@
    | Ps         -- ^ process listing @sysctl(2)@ interfaces
    | Recvfd     -- ^ receive file descriptors with @recvmsg(2)@
    | Route      -- ^ inspect the routing table
    | Rpath      -- ^ read-only filesystem operations
    | Sendfd     -- ^ send file descriptors with @sendmsg(2)@
    | Settime    -- ^ set system time
    | Stdio      -- ^ basic memory, fd, timer and process-attribute operations
    | Tape       -- ^ tape drive @ioctl@ operations
    | Tty        -- ^ tty @ioctl@ operations and @\/dev\/tty@ access
    | Unix       -- ^ @AF_UNIX@ socket operations
    | Unveil     -- ^ allow @unveil(2)@ to be called
    | Video      -- ^ video(4) @ioctl@ operations
    | Vminfo     -- ^ virtual-memory inspection (@top(1)@, @vmstat(8)@)
    | Vmm        -- ^ vmm(4) @ioctl@ operations
    | Wpath      -- ^ write filesystem operations
    | Wroute     -- ^ change the routing table
    deriving (Eq, Ord, Enum, Bounded, Show, Read)

-- | The string name of a promise, exactly as accepted by @pledge(2)@.
-- The 'Show' instance is derived and must not be used for
-- serialization.
promiseName :: Promise -> String
promiseName Audio     = "audio"
promiseName Bpf       = "bpf"
promiseName Chown     = "chown"
promiseName Cpath     = "cpath"
promiseName Disklabel = "disklabel"
promiseName Dns       = "dns"
promiseName Dpath     = "dpath"
promiseName Drm       = "drm"
promiseName Error     = "error"
promiseName Exec      = "exec"
promiseName Fattr     = "fattr"
promiseName Flock     = "flock"
promiseName Getpw     = "getpw"
promiseName Id        = "id"
promiseName Inet      = "inet"
promiseName Mcast     = "mcast"
promiseName Pf        = "pf"
promiseName Proc      = "proc"
promiseName ProtExec  = "prot_exec"
promiseName Ps        = "ps"
promiseName Recvfd    = "recvfd"
promiseName Route     = "route"
promiseName Rpath     = "rpath"
promiseName Sendfd    = "sendfd"
promiseName Settime   = "settime"
promiseName Stdio     = "stdio"
promiseName Tape      = "tape"
promiseName Tty       = "tty"
promiseName Unix      = "unix"
promiseName Unveil    = "unveil"
promiseName Video     = "video"
promiseName Vminfo    = "vminfo"
promiseName Vmm       = "vmm"
promiseName Wpath     = "wpath"
promiseName Wroute    = "wroute"

promiseList :: [Promise] -> String
promiseList = unwords . map promiseName

withMaybeCString :: Maybe String -> (CString -> IO a) -> IO a
withMaybeCString Nothing  action = action nullPtr
withMaybeCString (Just s) action = withCString s action

-- | Restrict the calling process to the given promises.
--
-- This sets the /current/ promises of the process.  Once a promise has
-- been revoked it cannot be regained: subsequent calls may only reduce
-- the set further, and an attempt to increase it fails with an @EPERM@
-- 'IOError'.
pledge :: [Promise] -> IO ()
pledge promises = pledgeRaw (Just promises) Nothing

-- | Restrict future child processes, executed with @execve(2)@, to the
-- given promises.
--
-- This sets the /exec/ promises: any future program executed by this
-- process starts with exactly these promises (unless the executed file
-- has setuid\/setgid bits, in which case execution is blocked with
-- @EACCES@).  The current process is unaffected.
pledgeChild :: [Promise] -> IO ()
pledgeChild promises = pledgeRaw Nothing (Just promises)

-- | Restrict both the current process and future children in a single
-- @pledge(2)@ call.
pledgeBoth :: [Promise] -> [Promise] -> IO ()
pledgeBoth promises execPromises =
    pledgeRaw (Just promises) (Just execPromises)

-- | The faithful interface to @pledge(promises, execpromises)@.
--
-- 'Nothing' maps to @NULL@, which means \"do not change this value\".
-- @'Just' []@ maps to the empty string @\"\"@, which restricts the
-- process to the @_exit(2)@ system call.  @'Just' ps@ sets the
-- promises to @ps@.  The first argument is the promises and the second
-- the exec promises of @pledge(2)@, respectively.
pledgeRaw :: Maybe [Promise] -> Maybe [Promise] -> IO ()
pledgeRaw promises execPromises =
    withMaybeCString (promiseList <$> promises) $ \cPromises ->
    withMaybeCString (promiseList <$> execPromises) $ \cExecPromises -> do
        result <- c_pledge cPromises cExecPromises
        when (result /= 0) $ throwErrno "pledge"
