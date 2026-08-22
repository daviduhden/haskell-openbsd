-- |
-- Module      : System.OpenBSD.Chroot
-- Description : OpenBSD chroot(2): change the filesystem root
--
-- Binding to OpenBSD's @chroot(2)@ system call, which changes the
-- root directory used for resolving absolute pathnames.
--
-- @chroot(2)@ is /not/ a complete sandbox:
--
-- * it only changes filesystem pathname resolution;
-- * it requires superuser privileges (@EPERM@ otherwise);
-- * it does not replace @pledge(2)@, @unveil(2)@ or privilege
--   dropping;
-- * a root process may still be able to escape the new root;
-- * already-open file descriptors retain access to resources outside
--   the new root.
--
-- Privilege dropping should normally follow chroot.  Note that
-- @chroot(2)@ is not permitted at all once the process has called
-- @pledge(2)@: it is not covered by any promise, so it must be
-- performed before pledging.
module System.OpenBSD.Chroot
    ( -- * Changing the filesystem root
      chroot
    , enterChroot
    ) where

import Control.Exception (mask_)
import Foreign.C.Error (throwErrnoPathIfMinus1_)
import Foreign.C.String (withCString)
import System.OpenBSD.Internal (c_chroot, checkNoNul)
import System.Posix.Directory (changeWorkingDirectory)

-- | The raw @chroot(2)@ call: change the root directory used for
-- resolving absolute pathnames.
--
-- This is the exact native operation with no additional policy.  When
-- a process is not already chrooted, @chroot(2)@ does not change its
-- current working directory, so an open @\"..\"@ can leave the new
-- root; consider 'enterChroot' for the security-sensitive transition.
-- Requires root privileges; the path must not contain embedded @NUL@
-- bytes.
chroot :: FilePath -> IO ()
chroot path = do
    checkNoNul "chroot" path
    withCString path $ \cPath ->
        throwErrnoPathIfMinus1_ "chroot" path $
            c_chroot cPath

-- | Perform the security-sensitive chroot transition:
--
-- > chroot(path) -> chdir("/")
--
-- as one masked operation.  Changing the working directory to the
-- new root closes the classic @\"..\"@ escape.  The whole transition
-- runs with asynchronous exceptions masked, so another Haskell thread
-- cannot interrupt it between the two calls.
--
-- The transition is irreversible and only partially protected on
-- failure: if @chroot@ succeeds but @chdir@ fails, the process is
-- already inside the new root and cannot simply be restored.  Any
-- exception from this function must therefore be treated as fatal for
-- the current process.
enterChroot :: FilePath -> IO ()
enterChroot path = do
    checkNoNul "enterChroot" path
    mask_ $ do
        chroot path
        changeWorkingDirectory "/"
