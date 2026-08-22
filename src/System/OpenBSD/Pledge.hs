-- |
-- Module      : System.OpenBSD.Pledge
-- Description : OpenBSD pledge(2): restrict system operations
--
-- Binding to OpenBSD's @pledge(2)@ system call, which partitions the
-- POSIX feature set into subsystems (\"promises\") and aborts the
-- process with an uncatchable @SIGABRT@ if it uses operations outside
-- the declared set.
--
-- Every call is /monotonic/: it may only reduce the set of available
-- promises.  Attempts to increase permissions fail with an @EPERM@
-- 'System.IO.Error.IOError' (unless the 'Error' promise is active, in
-- which case the increase is silently ignored).  Once revoked, a
-- promise can never be regained; there is deliberately no bracket
-- combinator in this module, because the restriction cannot be
-- undone.
--
-- These operations change process-wide security state and should
-- normally be performed before arbitrary concurrent application work
-- begins.
module System.OpenBSD.Pledge
    ( -- * Promises
      Promise(..)
    , promiseName
    , promiseFromName
      -- * Restricting the current process
    , pledge
      -- * Restricting future children (exec promises)
    , pledgeChild
    , pledgeBoth
      -- * Full control over both parts of pledge(2)
    , pledgeParts
    ) where

import Foreign.C.Error (throwErrnoIfMinus1_)
import System.OpenBSD.Internal (c_pledge, withMaybeCString)

-- | A pledge promise, i.e. a subsystem of system operations that may be
-- requested in a call to @pledge(2)@.
--
-- This enumeration matches the promise list accepted by the kernel on
-- OpenBSD 7.9 and OpenBSD-current (see @sys\/kern\/kern_pledge.c@).
-- The @\"tmppath\"@ promise is deliberately /not/ represented: it was
-- removed from OpenBSD, and using it causes @pledge(2)@ to fail with
-- @EINVAL@.
--
-- The 'Show' instance is derived and renders Haskell constructor
-- names; use 'promiseName' for native serialization.
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
    deriving (Eq, Ord, Enum, Bounded, Show)

-- | The string name of a promise, exactly as accepted by @pledge(2)@.
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

-- | Parse a single promise name, exactly as accepted by @pledge(2)@.
--
-- 'Nothing' for anything else, including the removed @\"tmppath\"@
-- promise (which the kernel rejects with @EINVAL@).  Useful for
-- reading promise sets from configuration; always round-trips with
-- 'promiseName'.
promiseFromName :: String -> Maybe Promise
promiseFromName name = lookup name
    [ (promiseName promise, promise)
    | promise <- [minBound .. maxBound]
    ]

promiseList :: [Promise] -> String
promiseList = unwords . map promiseName

-- | Restrict the calling process to the given promises, as
-- @pledge(promises, NULL)@.
--
-- This sets the /current/ promises of the process.  Once a promise
-- has been revoked it cannot be regained: subsequent calls may only
-- reduce the set further, and an attempt to increase it fails with an
-- @EPERM@ 'System.IO.Error.IOError'.  The restriction cannot be
-- undone, not even by re-executing the process.
pledge :: [Promise] -> IO ()
pledge promises = pledgeParts (Just promises) Nothing

-- | Restrict future child processes, executed with @execve(2)@, to
-- the given promises, as @pledge(NULL, execpromises)@.
--
-- This sets the /exec/ promises: any future program executed by this
-- process starts with exactly these promises (unless the executed
-- file has setuid\/setgid bits, in which case execution is blocked
-- with @EACCES@).  It does /not/ restrict the current process: the
-- caller's ordinary system calls keep working under its current
-- promise set.
--
-- The setting is monotonic and cannot be widened later, and it is
-- inherited across @fork(2)@: OpenBSD copies the exec-promise state
-- into every descendant, which applies it when that descendant
-- executes a new image.  It is therefore suitable as a shared
-- promise ceiling for all future executed descendants, and the
-- preferred way to configure the pledge policy of a fork\/exec child
-- is to call this /in the parent, before forking/, keeping the
-- post-fork child limited to an immediate exec.  It is not suitable
-- when each child needs an unrelated or broader policy.
--
-- If the calling process has already pledged itself, its /current/
-- promises must still allow the operations it performs (a fork\/exec
-- sequence generally needs @proc@ and @exec@); the exec promises are
-- a separate mechanism.
pledgeChild :: [Promise] -> IO ()
pledgeChild promises = pledgeParts Nothing (Just promises)

-- | Restrict both the current process and future children in a single
-- @pledge(2)@ call, as @pledge(promises, execpromises)@.
--
-- Both parts are reduced atomically.  This is not a substitute for
-- 'pledgeChild' when the intent is only to constrain future execs:
-- the current process is restricted immediately, which may be
-- inappropriate (and, for extreme current-process reductions, is
-- unsafe in a post-fork runtime environment).
pledgeBoth :: [Promise] -> [Promise] -> IO ()
pledgeBoth promises execPromises =
    pledgeParts (Just promises) (Just execPromises)

-- | The full typed interface to @pledge(promises, execpromises)@.
--
-- The two arguments are the promises and the exec promises of
-- @pledge(2)@, respectively:
--
-- * 'Nothing' maps to @NULL@: do not change this value;
-- * @'Just' []@ maps to the empty string @\"\"@: restrict this value
--   to nothing (an empty promise set allows only @_exit(2)@);
-- * @'Just' ps@ sets this value to @ps@.
--
-- Both parts are changed in a single native call, so current and exec
-- promises can be restricted atomically.
--
-- Note about the empty promise set: @\"\"@ is a valid OpenBSD
-- operation, but applying an @_exit(2)@-only restriction to a normal
-- live Haskell process is generally incompatible with the runtime,
-- because the RTS itself performs system calls.  This is particularly
-- significant with @-threaded@ and
-- 'System.Posix.Process.forkProcess': OpenBSD's pledge
-- transition may unwind sibling runtime threads, and their resumed
-- activity requires syscalls forbidden by the empty promise set, so
-- the kernel aborts the process.  For @_exit@-only workloads use
-- native code; for restricting a Haskell program, exec a separate
-- process image with a realistic promise policy (for example with
-- 'pledgeChild' immediately before @executeFile@).
pledgeParts :: Maybe [Promise] -> Maybe [Promise] -> IO ()
pledgeParts promises execPromises =
    withMaybeCString (promiseList <$> promises) $ \cPromises ->
    withMaybeCString (promiseList <$> execPromises) $ \cExecPromises ->
        throwErrnoIfMinus1_ "pledge" $
            c_pledge cPromises cExecPromises
