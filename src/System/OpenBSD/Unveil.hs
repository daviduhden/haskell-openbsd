{-# LANGUAGE CPP #-}

-- |
-- Module      : System.OpenBSD.Unveil
-- Description : OpenBSD unveil(2): restrict filesystem access
--
-- Binding to OpenBSD's @unveil(2)@ system call, which restricts the
-- filesystem view of a process to explicitly unveiled paths.
--
-- After rules have been installed, the configuration should be locked
-- with 'lockUnveil' (or 'unveilAndLock'): OpenBSD strongly recommends
-- locking, and once locked, further calls to 'unveil' fail with
-- @EPERM@.
module System.OpenBSD.Unveil
    ( -- * Permissions
      Permission(..)
    , permissionString
      -- * Installing rules
    , unveil
    , unveilPaths
      -- * Locking
    , lockUnveil
    , unveilAndLock
    ) where

import Control.Monad (when)
import Foreign.C.Error (throwErrno)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt(..))
import Foreign.Ptr (nullPtr)

#if defined(openbsd_HOST_OS)

foreign import ccall unsafe "unistd.h unveil"
    c_unveil :: CString -> CString -> IO CInt

#else

#error "The openbsd package requires OpenBSD: unveil(2) is an OpenBSD-only system call."

#endif

-- | An unveil permission.
data Permission
    = Read      -- ^ \"r\": read operations (pledge @rpath@)
    | Write     -- ^ \"w\": write operations (pledge @wpath@, @chown@, @fattr@)
    | Execute   -- ^ \"x\": execute operations (pledge @exec@)
    | Create    -- ^ \"c\": create and remove operations (pledge @cpath@, @dpath@, @unix@)
    deriving (Eq, Ord, Enum, Bounded, Show, Read)

permissionChar :: Permission -> Char
permissionChar Read    = 'r'
permissionChar Write   = 'w'
permissionChar Execute = 'x'
permissionChar Create  = 'c'

-- | Serialize a set of permissions to the string form accepted by
-- @unveil(2)@.  The empty list yields @\"\"@, which is valid: the path
-- is unveiled, but no operation on it is permitted.
permissionString :: [Permission] -> String
permissionString = map permissionChar

-- | Add a single unveil rule: make @path@ available with the given
-- permissions.
--
-- May be called repeatedly; the rules accumulate.  Fails with
-- @ENOENT@ if the path does not exist, @EINVAL@ for invalid
-- permissions, and @EPERM@ if the configuration is already locked or
-- the change would increase permissions.
unveil :: FilePath -> [Permission] -> IO ()
unveil path permissions =
    withCString path $ \cPath ->
    withCString (permissionString permissions) $ \cPermissions -> do
        result <- c_unveil cPath cPermissions
        when (result /= 0) $ throwErrno "unveil"

-- | Add multiple unveil rules.
unveilPaths :: [(FilePath, [Permission])] -> IO ()
unveilPaths = mapM_ (uncurry unveil)

-- | Permanently lock the unveil configuration, equivalent to
-- @unveil(NULL, NULL)@.
--
-- After locking, no further rules can be added: subsequent calls to
-- 'unveil' fail with @EPERM@.
lockUnveil :: IO ()
lockUnveil = do
    result <- c_unveil nullPtr nullPtr
    when (result /= 0) $ throwErrno "unveil"

-- | Install all the given rules and lock the unveil configuration.
--
-- Note that if the process is pledged, @unveil(2)@ itself requires the
-- @unveil@ promise.  Conversely, a @pledge(2)@ call that removes all
-- path-accessing promises (@rpath@, @wpath@, @cpath@, @dpath@,
-- @exec@, @unix@, @unveil@) destroys the unveil state.
unveilAndLock :: [(FilePath, [Permission])] -> IO ()
unveilAndLock paths = unveilPaths paths >> lockUnveil
