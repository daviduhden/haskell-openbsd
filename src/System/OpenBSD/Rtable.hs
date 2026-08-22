-- |
-- Module      : System.OpenBSD.Rtable
-- Description : OpenBSD routing domains (routing tables)
--
-- Binding to OpenBSD's routing domains: the @getrtable(2)@ and
-- @setrtable(2)@ system calls.  A routing domain (also called a
-- routing table or @rtable@) isolates the routing state of a
-- process, giving each domain its own routing table; domains are
-- referenced by a numeric ID.
--
-- These are process-wide settings: they apply to the calling process
-- and to sockets it creates.  Unlike @pledge(2)@ restrictions they
-- are /not/ monotonic — a sufficiently privileged process can switch
-- domains at will.
--
-- Reading the current domain is allowed under the @stdio@ pledge
-- promise; changing it requires the @id@ promise and root
-- privileges.
module System.OpenBSD.Rtable
    ( -- * Routing domains
      Rtable(..)
    , getRtable
    , setRtable
    ) where

import Foreign.C.Error (throwErrnoIfMinus1_)
import System.OpenBSD.Internal (c_getrtable, c_setrtable)

-- | A routing domain ID, as used by @getrtable(2)@ and
-- @setrtable(2)@.
--
-- The kernel validates the range on use: the constructor is exported
-- so callers can reference known domain IDs (for example @0@, the
-- default domain), but invalid values fail with @EINVAL@ at the
-- native boundary rather than being silently truncated or wrapped.
newtype Rtable = Rtable { unRtable :: Int }
    deriving (Eq, Ord, Show)

-- | Return the routing domain of the calling process, as
-- @getrtable(2)@.
--
-- Allowed under the @stdio@ pledge promise.
getRtable :: IO Rtable
getRtable = Rtable . fromIntegral <$> c_getrtable

-- | Set the routing domain of the calling process, as
-- @setrtable(2)@.
--
-- The documented privilege rule is asymmetric: an unprivileged
-- process may change the domain while it is @0@ (the default), but
-- once the domain is non-zero, only the superuser may change it
-- (@EPERM@ otherwise).  The @id@ pledge promise is required.  This
-- is a process-wide change but not a monotonic restriction: a
-- sufficiently privileged process can change the domain again later.
-- Sockets created after the change live in the new domain.
setRtable :: Rtable -> IO ()
setRtable (Rtable table) =
    throwErrnoIfMinus1_ "setrtable" $
        c_setrtable (fromIntegral table)
