-- |
-- Module      : System.OpenBSD.Process
-- Description : Process titles and daemonization
--
-- Two process-level facilities:
--
-- * safe @setproctitle(3)@: set the process title shown by ps(1);
-- * daemonization: detach from the controlling terminal and run in
--   the background.
--
-- Neither facility performs any security restriction itself; combine
-- them with 'System.OpenBSD.Pledge', 'System.OpenBSD.Unveil',
-- 'System.OpenBSD.Chroot' and 'System.OpenBSD.Privileges' as
-- required.  Foreground operation remains fully supported: nothing in
-- this package daemonizes automatically.
module System.OpenBSD.Process
    ( -- * Process titles
      setProcessTitle
    , resetProcessTitle
      -- * Daemonization
    , DaemonOptions(..)
    , defaultDaemonOptions
    , daemonize
    , daemonizeWith
    ) where

import Control.Monad (when)
import Foreign.C.String (withCString)
import System.Exit (ExitCode(..))
import System.IO (IOMode(..), hClose, openFile)
import System.OpenBSD.Internal (c_hsResetproctitle, c_hsSetproctitle,
                                checkNoNul)
import System.Posix.Directory (changeWorkingDirectory)
import System.Posix.IO (closeFd, dupTo, handleToFd, stdError, stdInput,
                        stdOutput)
import System.Posix.Process (createSession, exitImmediately, forkProcess)

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
daemonizeWith :: DaemonOptions -> IO () -> IO ()
daemonizeWith options daemonBody = do
    _ <- forkProcess $ do
        daemonizeChild options
        daemonBody
        exitImmediately ExitSuccess
    exitImmediately ExitSuccess
    exitImmediately ExitSuccess

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
