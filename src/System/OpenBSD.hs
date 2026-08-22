-- |
-- Module      : System.OpenBSD
-- Description : OpenBSD-specific security facilities
--
-- This package exposes the OpenBSD-specific security interfaces and
-- the privilege-separation practice common to OpenBSD daemons:
--
-- * 'System.OpenBSD.Pledge': @pledge(2)@ restricts which system
--   operations a process may perform.
--
-- * 'System.OpenBSD.Unveil': @unveil(2)@ restricts which filesystem
--   paths a process may access.
--
-- * 'System.OpenBSD.Privileges': drop real, effective and saved
--   UIDs\/GIDs the way OpenBSD base-system daemons do.
--
-- * 'System.OpenBSD.Chroot': @chroot(2)@ changes the filesystem root.
--
-- * 'System.OpenBSD.Credentials': @issetugid(2)@ execution taint and
--   @getpeereid(3)@ Unix-domain peer credentials.
--
-- * 'System.OpenBSD.Process': safe @setproctitle(3)@ and
--   daemonization.
--
-- * 'System.OpenBSD.Random': the @arc4random(3)@ family and
--   @getentropy(2)@.
--
-- * 'System.OpenBSD.Rtable': OpenBSD routing domains.
--
-- * 'System.OpenBSD.Memory': @mimmutable(2)@, secure erasure and
--   constant-time comparison.
--
-- * 'System.OpenBSD.Authentication': password hashing and key
--   derivation.
--
-- These mechanisms restrict different dimensions of process authority
-- (system calls, filesystem access, and credentials respectively) and
-- are normally complementary; a typical OpenBSD daemon uses several
-- of them.  None of the restrictions can be undone, and all of them
-- change process-wide security state, so they should normally be
-- applied in a defined order during initialization, before arbitrary
-- concurrent application work begins:
--
-- > main :: IO ()
-- > main = do
-- >     -- 1. privileged initialization: bind sockets, open logs,
-- >     --    resolve the target account
-- >     account <- accountByName "_mydaemon"
-- >     -- 2. name the process for ps(1)
-- >     setProcessTitle "mydaemon: serving"
-- >     -- 3. restrict the filesystem view
-- >     unveilAndLock
-- >         [ ("/",              [Read, Execute])
-- >         , ("/var/www",       [Read])
-- >         , ("/var/log/myapp", [Read, Write, Create])
-- >         ]
-- >     -- 4. restrict system calls, keeping what the drop still needs
-- >     pledge [Stdio, Rpath, Inet, Unix, Getpw, Id]
-- >     -- 5. drop credentials irreversibly
-- >     dropPrivilegesTo PrimaryGroupOnly account
-- >     -- 6. remove the identity-changing promises
-- >     pledge [Stdio, Rpath, Inet, Unix]
-- >     -- 7. main service loop (foreground)
-- >     serve
--
-- The promise sets above are illustrative: the promises an
-- application needs depend on the operations it performs, and the
-- precise ordering depends on the application's requirements (for
-- example, @chroot(2)@ and @getpeereid(3)@ must be performed before
-- pledging, and daemonization is optional under modern service
-- supervision).
--
-- The package can only be built and used on OpenBSD.
module System.OpenBSD
    ( module System.OpenBSD.Pledge
    , module System.OpenBSD.Unveil
    , module System.OpenBSD.Privileges
    , module System.OpenBSD.Chroot
    , module System.OpenBSD.Credentials
    , module System.OpenBSD.Process
    , module System.OpenBSD.Random
    , module System.OpenBSD.Rtable
    , module System.OpenBSD.Memory
    , module System.OpenBSD.Authentication
    ) where

import System.OpenBSD.Pledge
import System.OpenBSD.Unveil
import System.OpenBSD.Privileges
import System.OpenBSD.Chroot
import System.OpenBSD.Credentials
import System.OpenBSD.Process
import System.OpenBSD.Random
import System.OpenBSD.Rtable
import System.OpenBSD.Memory
import System.OpenBSD.Authentication
