-- |
-- Module      : System.OpenBSD.Process
-- Description : Process titles, exec and daemonization
--
-- Process-level facilities:
--
-- * safe @setproctitle(3)@: set the process title shown by ps(1);
-- * exec and fork\/exec under a pledge policy;
-- * daemonization: detach from the controlling terminal and run in
--   the background.
--
-- None of these facilities performs any security restriction by
-- itself beyond the pledge policy explicitly requested; combine them
-- with 'System.OpenBSD.Pledge', 'System.OpenBSD.Unveil',
-- 'System.OpenBSD.Chroot' and 'System.OpenBSD.Privileges' as
-- required.  Foreground operation remains fully supported: nothing in
-- this package daemonizes automatically.
--
-- ## Forking, exec and pledge
--
-- The supported model for creating a more restricted child process
-- from a Haskell program is:
--
-- > prepare everything in the parent
-- >     -> pledgeChild childPromises        (exec ceiling, parent-side)
-- >     -> forkProcess
-- >     -> executeFile immediately
-- >     -> the new image starts under childPromises
--
-- OpenBSD copies the exec-promise state across @fork(2)@ and applies
-- it when a descendant executes a new image, so the pledge policy of
-- a fork\/exec child can be configured entirely in the parent.  The
-- post-fork/pre-exec child then performs no pledge call and no other
-- meaningful Haskell work; its only purpose is to reach exec as
-- directly as possible.  'forkExec' and 'forkExecPledged' implement
-- exactly this pattern, including pre-fork validation of every
-- string that crosses the exec boundary.
--
-- The post-fork child is not a normal Haskell runtime environment:
-- 'System.Posix.Process.forkProcess' copies only the current thread
-- into the child, and upstream GHC documents that it is not well
-- supported with multiple capabilities (@+RTS -N@), although
-- @-threaded@ with one capability is supported.  Do not apply major
-- current-process pledge reductions in that window: reducing the
-- current promise set to an extreme restriction requires the kernel
-- to unwind sibling runtime threads while cleaning up unveil state,
-- and the resumed runtime threads then perform syscalls forbidden by
-- the fresh restriction, so the kernel aborts the process.  In
-- particular, the @_exit(2)@-only state ('System.OpenBSD.Pledge.pledge'
-- with an empty promise list) must not be entered from a live
-- threaded Haskell child; its native semantics are verified by a
-- standalone C probe in the test suite.
--
-- Setting exec promises in the parent is monotonic and affects every
-- future exec from that process and its descendants: use it when
-- those descendants share a common promise ceiling.  Independent
-- per-child policies require a fresh-process boundary (for example a
-- minimal native launcher), which this package does not provide.
module System.OpenBSD.Process
    ( -- * Process titles
      setProcessTitle
    , resetProcessTitle
      -- * Exec under a pledge policy
    , execPledged
      -- * Fork and exec under a pledge policy
    , forkExec
    , forkExecPledged
      -- * Descriptor management
    , closeFrom
    , getDescriptorCount
      -- * Program name
    , setProgramName
    , getProgramName
      -- * Daemonization
    , DaemonOptions(..)
    , defaultDaemonOptions
    , daemonize
    , daemonizeWith
    ) where

import Control.Monad (when)
import Foreign.C.String (peekCString, withCString)
import System.Exit (ExitCode(..))
import System.IO (IOMode(..), hClose, openFile)
import System.OpenBSD.Internal (c_hsResetproctitle, c_hsSetproctitle,
                                checkNoNul)
import System.OpenBSD.Pledge (Promise, pledgeChild)
import System.Posix.Directory (changeWorkingDirectory)
import System.OpenBSD.Internal (c_closefrom, c_getdtablecount,
                                c_getprogname, c_setprogname)
import System.Posix.IO (closeFd, dupTo, handleToFd, stdError, stdInput,
                        stdOutput)
import System.Posix.Process (createSession, executeFile,
                             exitImmediately, forkProcess)
import System.Posix.Types (Fd(..), ProcessID)

-- | Set the process title, as @setproctitle(\"%s\", title)@.
--
-- The supplied string is passed purely as /data/: the fixed format
-- literal @\"%s\"@ lives in the package's C shim, so titles
-- containing format characters (for example @\"%s %n %x\"@) can never
-- be interpreted as a format string.  This is exactly the secure
-- idiom required by the OpenBSD manual page.
--
-- The title is limited to 2048 bytes, so a longer string is
-- truncated.  The title must not contain embedded @NUL@ bytes.  The
-- operation is process-global; it works under the @stdio@ pledge
-- promise.
setProcessTitle :: String -> IO ()
setProcessTitle title = do
    checkNoNul "setProcessTitle" title
    withCString title $ \cTitle ->
        c_hsSetproctitle cTitle

-- | Reset the process title to just the program name, as
-- @setproctitle(NULL)@.
resetProcessTitle :: IO ()
resetProcessTitle = c_hsResetproctitle

-- | Replace the current process image with @executable@, starting it
-- under the given exec promise ceiling.
--
-- This is 'System.OpenBSD.Pledge.pledgeChild' immediately followed by
-- 'System.Posix.Process.executeFile': the current image is not
-- restricted by the pledge call, and the new program starts with
-- exactly @promises@.  Every argument and environment string is
-- validated (embedded @NUL@ bytes are rejected) before the pledge
-- state is touched, and 'executeFile' throws if the exec fails.
--
-- The usual way for a long-running process to finish by becoming a
-- more tightly restricted program.  The promise ceiling applies only
-- to the new image; the caller's current promise set (if it has
-- pledged itself) still governs this call, which requires @exec@
-- (and the serialization requires nothing beyond it).
--
-- An empty promise list is valid OpenBSD (the @_exit(2)@-only state)
-- but no ordinary runtime, including GHC's, can start under it; use
-- realistic promise sets for executable targets.
execPledged :: [Promise] -> FilePath -> Bool -> [String]
            -> Maybe [(String, String)] -> IO a
execPledged promises executable searchPath arguments environment = do
    validateExecArguments "execPledged" executable arguments environment
    pledgeChild promises
    executeFile executable searchPath arguments environment

-- | Fork a child that immediately executes @executable@, without
-- changing any pledge policy.
--
-- A thin, validated wrapper over 'System.Posix.Process.forkProcess'
-- + 'System.Posix.Process.executeFile': every argument and
-- environment string is checked for embedded @NUL@ bytes in the
-- parent before forking, and the child does nothing except reach
-- exec as directly as possible.  If the exec fails, the child exits
-- immediately with status 127.
--
-- If the calling process has already pledged itself, its current
-- promises must still allow @fork@ and @execve@ (generally @proc@
-- and @exec@).  The usual 'forkProcess' runtime caveats apply:
-- @-threaded@ with one capability is supported; multiple
-- capabilities are not well supported by upstream GHC.
forkExec :: FilePath -> Bool -> [String]
         -> Maybe [(String, String)] -> IO ProcessID
forkExec executable searchPath arguments environment = do
    validateExecArguments "forkExec" executable arguments environment
    forkProcess (execChild executable searchPath arguments environment)

-- | Fork a child that immediately executes @executable@ under the
-- given exec promise ceiling.
--
-- The supported fork\/exec architecture:
--
-- > pledgeChild promises        (in the caller, before forking)
-- > forkProcess
-- > executeFile immediately    (the child does nothing else)
--
-- OpenBSD preserves execpromises across @fork(2)@ and applies them
-- when the new image starts, so the executed program begins pledged
-- with exactly @promises@.  The post-fork child performs no pledge
-- call and no other meaningful Haskell work.
--
-- IMPORTANT side effect: this reduces the /caller's/ exec promises,
-- which is monotonic and cannot be widened later.  Every future exec
-- from the calling process and its descendants is then capped by
-- @promises@, so use this only when those descendants share a common
-- promise ceiling.  Independent per-child policies require a
-- fresh-process boundary instead.
--
-- The executable path, arguments and environment values are validated
-- in the caller before forking: embedded @NUL@ bytes are rejected.
-- If the exec fails, the child exits immediately with status 127.
--
-- If the calling process has already pledged itself, its current
-- promises must still allow @fork@ and @execve@ (generally @proc@
-- and @exec@).  The usual 'forkProcess' runtime caveats apply:
-- @-threaded@ with one capability is supported; multiple
-- capabilities are not well supported by upstream GHC.  An empty
-- promise list is valid OpenBSD (the @_exit(2)@-only state) but no
-- ordinary runtime can start under it.
forkExecPledged :: [Promise] -> FilePath -> Bool -> [String]
                -> Maybe [(String, String)] -> IO ProcessID
forkExecPledged promises executable searchPath arguments environment = do
    validateExecArguments "forkExecPledged" executable arguments environment
    pledgeChild promises
    forkProcess (execChild executable searchPath arguments environment)

execChild :: FilePath -> Bool -> [String]
          -> Maybe [(String, String)] -> IO ()
execChild executable searchPath arguments environment = do
    _ <- executeFile executable searchPath arguments environment
    _ <- exitImmediately (ExitFailure 127)
    pure ()

-- | Close all file descriptors greater than or equal to the given
-- one, as @closefrom(2)@.
--
-- The classic OpenBSD descriptor-leak prevention: daemons and
-- privilege-separated programs call it around spawn\/exec time, with
-- the descriptors to keep reserved at the low numbers.  The argument
-- itself is closed too, as are any runtime-managed descriptors above
-- it; afterwards the caller must not perform Handle-based I/O on the
-- closed descriptors (or must rebuild the relevant Handles).  A
-- descriptor beyond the table fails with the native @EBADF@.
--
-- Allowed under the @stdio@ pledge promise.
closeFrom :: Fd -> IO ()
closeFrom (Fd fd) = c_closefrom fd

-- | Return the current number of open file descriptors, as
-- @getdtablecount(2)@: one more than the highest open descriptor.
--
-- Useful for auditing and for descriptor-hygiene checks around
-- spawn and privilege-separation boundaries.  Allowed under the
-- @stdio@ pledge promise.
getDescriptorCount :: IO Int
getDescriptorCount = fromIntegral <$> c_getdtablecount

-- | Set the program name, as @setprogname(3)@.
--
-- The stored name is used by @setproctitle(NULL)@
-- ('resetProcessTitle') and by diagnostic messages; if the argument
-- contains a slash, the basename is used, matching the native
-- behavior.  The name must not contain embedded @NUL@ bytes.
setProgramName :: String -> IO ()
setProgramName name = do
    checkNoNul "setProgramName" name
    withCString name c_setprogname

-- | Return the stored program name, as @getprogname(3)@.
getProgramName :: IO String
getProgramName = c_getprogname >>= peekCString

-- | Reject embedded NUL bytes in every string that will cross the
-- exec boundary.  Runs entirely in the caller, before any fork or
-- pledge state change, and doubles as a forcing pass so the child
-- never triggers unexpected lazy evaluation of these values.
validateExecArguments :: String -> FilePath -> [String]
                      -> Maybe [(String, String)] -> IO ()
validateExecArguments what executable arguments environment = do
    mapM_ (checkNoNul what) (executable : arguments)
    mapM_ (checkNoNul what) (concatMap (\(name, value) -> [name, value]) envList)
  where
    envList = maybe [] id environment

-- | Options controlling 'daemonizeWith'.  The fields are named
-- positively, unlike the inverted @nochdir@\/@noclose@ arguments of
-- @daemon(3)@.
data DaemonOptions = DaemonOptions
    { changeDirectoryToRoot :: Bool
      -- ^ Whether to change the working directory to @\/@ (the
      -- default).  Leaving it 'False' keeps the current directory,
      -- which can prevent an unmount of the filesystem it lives on.
    , redirectStandardStreams :: Bool
      -- ^ Whether to redirect standard input, output and error to
      -- @\/dev\/null@ (the default).
    } deriving (Eq, Show)

-- | The default daemonization behavior:
-- 'changeDirectoryToRoot' and 'redirectStandardStreams' both 'True'.
defaultDaemonOptions :: DaemonOptions
defaultDaemonOptions = DaemonOptions
    { changeDirectoryToRoot = True
    , redirectStandardStreams = True
    }

-- | Daemonize the given action: run it in a background process that
-- is detached from the controlling terminal, with the default
-- @DaemonOptions@.
--
-- Equivalent to calling @daemon(3)@ with @nochdir == 0@ and
-- @noclose == 0@ and then running the action in the resulting
-- daemon process.
daemonize :: IO () -> IO ()
daemonize = daemonizeWith defaultDaemonOptions

-- | Daemonize the given action with explicit options.  The action
-- runs in the newly detached child process; the original process
-- exits, exactly as with @daemon(3)@.
--
-- The implementation deliberately does /not/ call libc @daemon(3)@:
-- that function forks and then exits the parent with a raw C
-- @_exit(2)@ behind the GHC runtime, leaving the surviving child to
-- run Haskell after a raw @fork(2)@ without any runtime
-- reinitialization.  This is unsafe with the GHC runtime, especially
-- the threaded runtime.  Instead the same behavior is reproduced with
-- runtime-aware primitives:
--
-- > forkProcess (setsid; chdir("/") if requested; redirect 0\/1\/2
-- > to /dev/null if requested; run the action)
--
-- and the original process exits with @exit(3)@ so the runtime shuts
-- down cleanly.
--
-- As with @daemon(3)@, the caller never observes failures that occur
-- after the fork: errors in @setsid(2)@ or the redirection are
-- reported by the daemonized child, not by this function.
--
-- Caveat: when standard streams are redirected, descriptors 0, 1 and
-- 2 are assumed to be the standard streams; if the caller has closed
-- them and repurposed the numbers, the redirection clobbers whatever
-- now occupies them (the same caveat as @daemon(3)@).  Programs that
-- have already reused those descriptors should pass
-- 'redirectStandardStreams' 'False' and manage the streams
-- themselves.
--
-- When running under @pledge(2)@, this needs the @proc@ promise
-- (fork\/setsid), @rpath@ (chdir), and @rpath@/@wpath@ (opening
-- @\/dev\/null@); the recommended order is to daemonize before
-- pledging.
--
-- Modern service supervision commonly expects foreground operation;
-- only call this when detachment is actually required.
--
-- The daemon body runs in a 'System.Posix.Process.forkProcess' child:
-- keep its early post-fork phase free of major pledge reductions (see
-- the \"Forking, exec and pledge\" guidance in the module
-- documentation) and prepare everything expensive before forking.
daemonizeWith :: DaemonOptions -> IO () -> IO ()
daemonizeWith options daemonBody = do
    _ <- forkProcess $ do
        daemonizeChild options
        daemonBody
        exitImmediately ExitSuccess
    exitImmediately ExitSuccess >> pure ()

daemonizeChild :: DaemonOptions -> IO ()
daemonizeChild options = do
    _ <- createSession
    when (changeDirectoryToRoot options) (changeWorkingDirectory "/")
    when (redirectStandardStreams options) redirectToDevNull

redirectToDevNull :: IO ()
redirectToDevNull = do
    nullHandle <- openFile "/dev/null" ReadWriteMode
    nullFd <- handleToFd nullHandle
    mapM_ (dupTo nullFd) [stdInput, stdOutput, stdError]
    closeFd nullFd
    hClose nullHandle
