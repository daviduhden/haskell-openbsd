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
-- The high-level operations verify the resulting identity and raise an
-- exception if any part of the drop did not take effect.
module System.OpenBSD.Privileges
    ( -- * Accounts
      Account(..)
    , accountByName
      -- * Supplementary group policy
    , GroupPolicy(..)
      -- * High-level privilege dropping
    , dropPrivileges
    , dropPrivilegesWith
    , dropPrivilegesTo
      -- * Low-level identity operations
    , setResUid
    , setResGid
    , getResUid
    , getResGid
    , initGroups
      -- * Types re-exported for convenience
    , UserID
    , GroupID
    ) where

import Control.Monad (when)
import Foreign.C.Error (throwErrno)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt(..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import System.Posix.Types (CGid(..), CUid(..), GroupID, UserID)
import System.Posix.User (getGroups, getUserEntryForName, setGroups,
                          userGroupID, userID)

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

-- | A resolved user account: the identity a process will be dropped
-- to.
data Account = Account
    { accountName :: String  -- ^ the login name
    , accountUid  :: UserID  -- ^ the user ID
    , accountGid  :: GroupID -- ^ the primary group ID
    } deriving (Eq, Show)

-- | Resolve a user name to an @Account@.
--
-- Look up the account while still privileged: after @chroot(2)@ the
-- password database may no longer be reachable.  Under @pledge(2)@,
-- resolution requires the @getpw@ promise.
accountByName :: String -> IO Account
accountByName name = do
    entry <- getUserEntryForName name
    pure Account
        { accountName = name
        , accountUid = userID entry
        , accountGid = userGroupID entry
        }

-- | Policy controlling how supplementary groups are set when dropping
-- privileges.
data GroupPolicy
    = ReplaceSupplementaryGroups
      -- ^ Replace the supplementary group list with only the target
      -- account's primary GID.  This is the restrictive, daemon-style
      -- behavior used by OpenBSD base-system daemons (the equivalent
      -- of @setgroups(1, \&pw_gid)@) and the default of
      -- 'dropPrivileges'.
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
-- real, effective and saved UIDs\/GIDs are verified to be the target
-- values; any mismatch raises an exception.  The calling process must
-- have sufficient privilege (typically @root@); otherwise each step
-- fails with an @EPERM@ 'IOError' and the exception reports exactly
-- which step failed.
--
-- If the process has called @pledge(2)@, it must still hold the @id@
-- promise (for the identity-changing calls) and the @getpw@ promise
-- (for account resolution) until the drop is complete.  Afterwards,
-- @pledge(2)@ can be called again without them.
dropPrivileges :: String -> IO ()
dropPrivileges = dropPrivilegesWith ReplaceSupplementaryGroups

-- | Like 'dropPrivileges', but with an explicit 'GroupPolicy'.
dropPrivilegesWith :: GroupPolicy -> String -> IO ()
dropPrivilegesWith policy name =
    accountByName name >>= dropPrivilegesTo policy

-- | Drop privileges to a previously resolved account.
--
-- Useful when the account must be resolved while still privileged
-- (for example, before @chroot(2)@ makes the password database
-- unavailable) but privileges dropped later.
dropPrivilegesTo :: GroupPolicy -> Account -> IO ()
dropPrivilegesTo policy account = do
    let name = accountName account
        uid = accountUid account
        gid = accountGid account
    case policy of
        ReplaceSupplementaryGroups -> setGroups [gid]
        Initgroups -> initGroups name gid
    setResGid gid gid gid
    setResUid uid uid uid
    verifyDrop policy account

verifyDrop :: GroupPolicy -> Account -> IO ()
verifyDrop policy account = do
    let name = accountName account
        uid = accountUid account
        gid = accountGid account
    rUid <- getResUid
    rGid <- getResGid
    groups <- getGroups
    let groupsOk = case policy of
            ReplaceSupplementaryGroups -> groups == [gid]
            Initgroups -> gid `elem` groups
    when (rUid /= (uid, uid, uid) || rGid /= (gid, gid, gid) || not groupsOk) $
        ioError (userError
            ("dropPrivileges: verification failed for " ++ name
                ++ ": real/effective/saved uid = " ++ show rUid
                ++ ", real/effective/saved gid = " ++ show rGid
                ++ ", supplementary groups = " ++ show groups))

-- | Set the real, effective and saved UIDs atomically, as
-- @setresuid(2)@.
setResUid :: UserID -> UserID -> UserID -> IO ()
setResUid ruid euid suid = do
    result <- c_setresuid ruid euid suid
    when (result /= 0) $ throwErrno "setresuid"

-- | Set the real, effective and saved GIDs atomically, as
-- @setresgid(2)@.
setResGid :: GroupID -> GroupID -> GroupID -> IO ()
setResGid rgid egid sgid = do
    result <- c_setresgid rgid egid sgid
    when (result /= 0) $ throwErrno "setresgid"

-- | Query the real, effective and saved UIDs.
getResUid :: IO (UserID, UserID, UserID)
getResUid =
    alloca $ \ruid ->
    alloca $ \euid ->
    alloca $ \suid -> do
        result <- c_getresuid ruid euid suid
        when (result /= 0) $ throwErrno "getresuid"
        (,,) <$> peek ruid <*> peek euid <*> peek suid

-- | Query the real, effective and saved GIDs.
getResGid :: IO (GroupID, GroupID, GroupID)
getResGid =
    alloca $ \rgid ->
    alloca $ \egid ->
    alloca $ \sgid -> do
        result <- c_getresgid rgid egid sgid
        when (result /= 0) $ throwErrno "getresgid"
        (,,) <$> peek rgid <*> peek egid <*> peek sgid

-- | Initialize the supplementary group access list for @name@, as
-- @initgroups(3)@.  This is the login-style group initialization used
-- by the 'Initgroups' policy.
initGroups :: String -> GroupID -> IO ()
initGroups name baseGid =
    withCString name $ \cName -> do
        result <- c_initgroups cName baseGid
        when (result /= 0) $ throwErrno "initgroups"
