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
-- are normally complementary.
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
