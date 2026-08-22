-- |
-- Module      : System.OpenBSD.Privileges
-- Description : Drop privileges the OpenBSD way
--
-- Implements the privilege-dropping sequence used by OpenBSD
-- base-system daemons such as httpd(8), unwind(8) and smtpd(8):
--
-- 1. resolve the target account while still privileged;
-- 2. reduce supplementary groups while still privileged
--    (@setgroups(2)@ to the primary GID only, or @initgroups(3)@);
-- 3. drop the real, effective and saved GIDs (@setresgid(2)@);
-- 4. drop the real, effective and saved UIDs last (@setresuid(2)@).
--
-- This ordering matters: @setgroups(2)@ requires privilege, and once
-- root is gone the saved IDs must not allow the process to regain it.
-- The high-level operations verify the resulting identity and raise
-- an exception if any part of the drop did not take effect; the whole
-- transition is performed with asynchronous exceptions masked so that
-- it cannot be interrupted halfway through by another Haskell thread.
--
-- Privilege dropping is intended as an initialization transition.
-- These operations change process-wide security state, are not
-- restorable, and should normally be performed before arbitrary
-- concurrent application work begins.
module System.OpenBSD.Privileges
    ( -- * Accounts
      Account(..)
    , accountByName
    , lookupAccountByName
      -- * Supplementary group policy
    , GroupPolicy(..)
      -- * High-level privilege dropping
    , dropPrivileges
    , dropPrivilegesWith
    , dropPrivilegesTo
      -- * Low-level identity operations
    , setResUserID
    , setResGroupID
    , getResUserID
    , getResGroupID
    , initGroups
      -- * Types re-exported for convenience
    , UserID
    , GroupID
    ) where

import Control.Exception (catch, mask_, throwIO)
import Control.Monad (when)
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.C.String (withCString)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Storable (peek)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Types (GroupID, UserID)
import System.Posix.User (getGroups, getUserEntryForName, setGroups,
                          userGroupID, userID)
import System.OpenBSD.Internal (c_getresgid, c_getresuid, c_initgroups,
                                c_setresgid, c_setresuid, checkNoNul)

-- | A resolved user account: the identity a process will be dropped
-- to.
--
-- Constructors are exported deliberately: configuring a daemon from
-- known numeric UID\/GID values is a legitimate use, and the kernel
-- still enforces that identity-changing calls are only honored from a
-- sufficiently privileged process.
data Account = Account
    { accountName :: String  -- ^ the login name
    , accountUid  :: UserID  -- ^ the user ID
    , accountGid  :: GroupID -- ^ the primary group ID
    } deriving (Eq, Show)

-- | Resolve a user name to an @Account@.
--
-- Look up the account while still privileged: after @chroot(2)@ the
-- password database may no longer be reachable.  Under @pledge(2)@,
-- resolution requires the @getpw@ promise.  The name must not contain
-- embedded @NUL@ bytes.
accountByName :: String -> IO Account
accountByName name = do
    checkNoNul "accountByName" name
    entry <- getUserEntryForName name
    pure Account
        { accountName = name
        , accountUid = userID entry
        , accountGid = userGroupID entry
        }

-- | Like 'accountByName', but returns 'Nothing' when the user does
-- not exist instead of raising an exception.  I\/O failures other
-- than a missing user are still raised.
lookupAccountByName :: String -> IO (Maybe Account)
lookupAccountByName name =
    (Just <$> accountByName name)
        `catch` \e ->
            if isDoesNotExistError e
                then pure Nothing
                else throwIO e

-- | Policy controlling how supplementary groups are set when dropping
-- privileges.
data GroupPolicy
    = PrimaryGroupOnly
      -- ^ Replace the supplementary group list with only the target
      -- account's primary GID.  This is the restrictive, daemon-style
      -- behavior used by OpenBSD base-system daemons (the equivalent
      -- of @setgroups(1, \&pw_gid)@) and the default of
      -- 'dropPrivileges'.  It can never accidentally retain root's
      -- supplementary groups.
    | Initgroups
      -- ^ Adopt all supplementary groups associated with the account
      -- via @initgroups(3)@.  This is login-style behavior; use it
      -- only when the process genuinely needs the account's group
      -- memberships.
    deriving (Eq, Show)

-- | Drop privileges to the given account, OpenBSD daemon style.
--
-- Resolves the account, then performs the same irreversible sequence
-- used by OpenBSD base-system daemons.  After the call returns, the
-- real, effective and saved UIDs\/GIDs and the supplementary groups
-- are verified to be the expected values; any mismatch raises an
-- exception.  The calling process must have sufficient privilege
-- (typically @root@); otherwise each step fails with an @EPERM@
-- 'System.IO.Error.IOError' and the exception reports exactly which
-- step failed.
--
-- The whole transition runs with asynchronous exceptions masked: once
-- it starts, another Haskell thread cannot interrupt it halfway
-- through (for example, after groups have been dropped but before the
-- saved IDs are gone).  Synchronous failures are still raised with
-- their underlying @errno@.
--
-- If a step fails partway through, the process may already have
-- reduced privileges and /must not/ continue normal service
-- execution: treat any exception from this function as fatal for the
-- current process.
--
-- If the process has called 'System.OpenBSD.Pledge.pledge', it must
-- still hold the @id@ promise (for the identity-changing calls) and
-- the @getpw@ promise (for account resolution) until the drop is
-- complete.  Afterwards, 'System.OpenBSD.Pledge.pledge' can be called
-- again without them.
dropPrivileges :: String -> IO ()
dropPrivileges = dropPrivilegesWith PrimaryGroupOnly

-- | Like 'dropPrivileges', but with an explicit @GroupPolicy@.
dropPrivilegesWith :: GroupPolicy -> String -> IO ()
dropPrivilegesWith policy name =
    accountByName name >>= dropPrivilegesTo policy

-- | Drop privileges to a previously resolved account.
--
-- Useful when the account must be resolved while still privileged
-- (for example, before @chroot(2)@ makes the password database
-- unavailable) but privileges dropped later.
dropPrivilegesTo :: GroupPolicy -> Account -> IO ()
dropPrivilegesTo policy account = mask_ $ do
    let name = accountName account
        uid = accountUid account
        gid = accountGid account
    case policy of
        PrimaryGroupOnly -> setGroups [gid]
        Initgroups -> initGroups name gid
    setResGroupID gid gid gid
    setResUserID uid uid uid
    verifyDrop policy account

verifyDrop :: GroupPolicy -> Account -> IO ()
verifyDrop policy account = do
    let name = accountName account
        uid = accountUid account
        gid = accountGid account
    rUid <- getResUserID
    rGid <- getResGroupID
    groups <- getGroups
    let groupsOk = case policy of
            PrimaryGroupOnly -> groups == [gid]
            Initgroups -> gid `elem` groups
    when (rUid /= (uid, uid, uid) || rGid /= (gid, gid, gid) || not groupsOk) $
        ioError (userError
            ("dropPrivilegesTo: verification failed for " ++ name
                ++ ": real/effective/saved uid = " ++ show rUid
                ++ ", real/effective/saved gid = " ++ show rGid
                ++ ", supplementary groups = " ++ show groups))

-- | Set the real, effective and saved user IDs atomically, as
-- @setresuid(2)@.
--
-- This is a process-wide, security-sensitive /mechanism/: a plain
-- wrapper around the native call with no policy attached.  Prefer the
-- high-level 'dropPrivileges' family unless you are implementing a
-- custom privilege-dropping sequence.
setResUserID :: UserID -> UserID -> UserID -> IO ()
setResUserID ruid euid suid =
    throwErrnoIfMinus1_ "setresuid" $
        c_setresuid ruid euid suid

-- | Set the real, effective and saved group IDs atomically, as
-- @setresgid(2)@.
--
-- This is a process-wide, security-sensitive /mechanism/ with no
-- policy attached; see 'setResUserID'.
setResGroupID :: GroupID -> GroupID -> GroupID -> IO ()
setResGroupID rgid egid sgid =
    throwErrnoIfMinus1_ "setresgid" $
        c_setresgid rgid egid sgid

-- | Query the real, effective and saved user IDs, as
-- @getresuid(2)@.
getResUserID :: IO (UserID, UserID, UserID)
getResUserID =
    alloca $ \ruid ->
    alloca $ \euid ->
    alloca $ \suid -> do
        throwErrnoIfMinus1_ "getresuid" $
            c_getresuid ruid euid suid
        (,,) <$> peek ruid <*> peek euid <*> peek suid

-- | Query the real, effective and saved group IDs, as
-- @getresgid(2)@.
getResGroupID :: IO (GroupID, GroupID, GroupID)
getResGroupID =
    alloca $ \rgid ->
    alloca $ \egid ->
    alloca $ \sgid -> do
        throwErrnoIfMinus1_ "getresgid" $
            c_getresgid rgid egid sgid
        (,,) <$> peek rgid <*> peek egid <*> peek sgid

-- | Initialize the supplementary group access list for @name@, as
-- @initgroups(3)@.  This is the login-style group initialization used
-- by the 'Initgroups' policy.
--
-- A mechanism, not a policy; requires privilege and the @id@ pledge
-- promise (plus @getpw@ for the group lookup).  The name must not
-- contain embedded @NUL@ bytes.
initGroups :: String -> GroupID -> IO ()
initGroups name baseGid = do
    checkNoNul "initGroups" name
    withCString name $ \cName ->
        throwErrnoIfMinus1_ "initgroups" $
            c_initgroups cName baseGid
