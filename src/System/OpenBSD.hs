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
-- These mechanisms restrict different dimensions of process authority
-- (system calls, filesystem access, and credentials respectively) and
-- are normally complementary; a typical OpenBSD daemon uses all
-- three.  None of them can be undone, and all of them change
-- process-wide security state, so they should normally be applied in
-- a defined order during initialization, before arbitrary concurrent
-- application work begins:
--
-- > main :: IO ()
-- > main = do
-- >     -- 1. privileged initialization: bind sockets, open logs,
-- >     --    resolve the target account
-- >     account <- accountByName "_mydaemon"
-- >     -- 2. restrict the filesystem view
-- >     unveilAndLock
-- >         [ ("/",              [Read, Execute])
-- >         , ("/var/www",       [Read])
-- >         , ("/var/log/myapp", [Read, Write, Create])
-- >         ]
-- >     -- 3. restrict system calls, keeping what the drop still needs
-- >     pledge [Stdio, Rpath, Inet, Unix, Getpw, Id]
-- >     -- 4. drop credentials irreversibly
-- >     dropPrivilegesTo PrimaryGroupOnly account
-- >     -- 5. remove the identity-changing promises
-- >     pledge [Stdio, Rpath, Inet, Unix]
-- >     -- 6. main service loop
-- >     serve
--
-- The promise sets above are illustrative: the promises an
-- application needs depend on the operations it performs.
--
-- The package can only be built and used on OpenBSD.
module System.OpenBSD
    ( module System.OpenBSD.Pledge
    , module System.OpenBSD.Unveil
    , module System.OpenBSD.Privileges
    ) where

import System.OpenBSD.Pledge
import System.OpenBSD.Unveil
import System.OpenBSD.Privileges
