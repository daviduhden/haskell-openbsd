-- |
-- Module      : System.OpenBSD.Unveil
-- Description : OpenBSD unveil(2): restrict filesystem access
--
-- Binding to OpenBSD's @unveil(2)@ system call, which restricts the
-- filesystem view of a process to explicitly unveiled paths.  The
-- first call removes visibility of the entire filesystem except for
-- the specified path; additional calls add further rules.
--
-- Once rules have been installed, the configuration should be locked
-- with 'lockUnveil' (or 'unveilAndLock'): OpenBSD strongly recommends
-- locking, and after locking, further 'unveil' calls fail with
-- @EPERM@.  Locking is irreversible.
--
-- If the process is pledged, @unveil(2)@ itself requires the @unveil@
-- promise.  Conversely, a @pledge(2)@ call that removes all
-- path-accessing promises (@rpath@, @wpath@, @cpath@, @dpath@,
-- @exec@, @unix@, @unveil@) destroys the unveil state.
--
-- Denied filesystem access surfaces as @EACCES@\/@ENOENT@ errors at
-- the point of the filesystem call, not as exceptions from this
-- module.  These operations change process-wide security state and
-- should normally be performed before arbitrary concurrent
-- application work begins.
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

import Foreign.C.Error (throwErrnoIfMinus1_, throwErrnoPathIfMinus1_)
import Foreign.C.String (withCString)
import Foreign.Ptr (nullPtr)
import System.OpenBSD.Internal (c_unveil, checkNoNul)

-- | An unveil permission.
--
-- The 'Show' instance is derived and renders Haskell constructor
-- names; use 'permissionString' for native serialization.
data Permission
    = Read      -- ^ \"r\": read operations (pledge @rpath@)
    | Write     -- ^ \"w\": write operations (pledge @wpath@, @chown@, @fattr@)
    | Execute   -- ^ \"x\": execute operations (pledge @exec@)
    | Create    -- ^ \"c\": create and remove operations (pledge @cpath@, @dpath@, @unix@)
    deriving (Eq, Ord, Enum, Bounded, Show)

permissionChar :: Permission -> Char
permissionChar Read    = 'r'
permissionChar Write   = 'w'
permissionChar Execute = 'x'
permissionChar Create  = 'c'

-- | Serialize a set of permissions to the string form accepted by
-- @unveil(2)@.  The empty list yields @\"\"@, which is valid: the
-- path is unveiled, but no operation on it is permitted.
permissionString :: [Permission] -> String
permissionString = map permissionChar

-- | Add a single unveil rule, as @unveil(path, permissions)@: make
-- @path@ available with the given permissions.
--
-- May be called repeatedly; the rules accumulate.  Fails with
-- @ENOENT@ if a directory in the path does not exist (a nonexistent
-- final component is valid and is remembered by name), @EINVAL@ for
-- invalid permissions, and @EPERM@ if the configuration is already
-- locked or the change would increase permissions.  The path must not
-- contain embedded @NUL@ bytes.
unveil :: FilePath -> [Permission] -> IO ()
unveil path permissions = do
    checkNoNul "unveil" path
    withCString path $ \cPath ->
        withCString (permissionString permissions) $ \cPermissions ->
            throwErrnoPathIfMinus1_ "unveil" path $
                c_unveil cPath cPermissions

-- | Add multiple unveil rules.
unveilPaths :: [(FilePath, [Permission])] -> IO ()
unveilPaths = mapM_ (uncurry unveil)

-- | Permanently lock the unveil configuration, equivalent to
-- @unveil(NULL, NULL)@.
--
-- After locking, no further rules can be added: subsequent calls to
-- 'unveil' fail with @EPERM@.  The lock cannot be undone.
lockUnveil :: IO ()
lockUnveil =
    throwErrnoIfMinus1_ "unveil" $
        c_unveil nullPtr nullPtr

-- | Install all the given rules and lock the unveil configuration.
unveilAndLock :: [(FilePath, [Permission])] -> IO ()
unveilAndLock paths = unveilPaths paths >> lockUnveil
