{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Main
-- Description : Test suite for the openbsd package
--
-- Pure tests (promise\/permission serialization, NUL rejection) run
-- everywhere.  Runtime tests exercise the real kernel interfaces and
-- must run on OpenBSD; tests that require root are skipped cleanly
-- otherwise.
--
-- All runtime tests run in forked child processes so that the test
-- runner itself never loses privileges or has its authority
-- restricted, and so that no test depends on the execution order of
-- any other test.
module Main (main) where

import Control.Exception (IOException, SomeException, displayException, try)
import Control.Monad (unless, void, when)
import Data.List (nub)
import Foreign.C.Types (CInt(..))
import System.Exit (ExitCode(..), exitWith)
import System.IO (BufferMode(..), hPutStrLn, hSetBuffering, stderr, stdout)
import System.IO.Error (isDoesNotExistError, isPermissionError, isUserError)
import System.Posix.Process (ProcessStatus(..), exitImmediately, forkProcess,
                             getProcessID, getProcessStatus)
import System.Posix.Signals (sigABRT)
import System.Posix.User (getEffectiveUserID, getGroups, getUserEntryForName,
                          userGroupID, userID)

import System.OpenBSD

foreign import ccall unsafe "unistd.h _exit"
    c__exit :: CInt -> IO ()

data Result = Pass | Skip String | Fail String

expect :: Bool -> String -> IO Result
expect condition reason = pure (if condition then Pass else Fail reason)

expectIOError :: String -> IO a -> IO Result
expectIOError context action = do
    result <- try action
    case result of
        Left (_ :: IOException) -> pure Pass
        Right _ -> pure (Fail ("expected an IOError: " ++ context))

runTests :: [(String, IO Result)] -> IO Bool
runTests = go True
  where
    go ok [] = pure ok
    go ok ((name, action) : rest) = do
        outcome <- try action
        case outcome of
            Left (e :: SomeException) -> do
                putStrLn ("FAIL " ++ name ++ ": " ++ displayException e)
                go False rest
            Right Pass -> putStrLn ("ok   " ++ name) >> go ok rest
            Right (Skip reason) ->
                putStrLn ("SKIP " ++ name ++ " (" ++ reason ++ ")") >> go ok rest
            Right (Fail reason) ->
                putStrLn ("FAIL " ++ name ++ ": " ++ reason) >> go False rest

-- | Run an action in a forked child process.  The child reports
-- success via its exit status; failures carry a message in a log file
-- or, if the log file cannot be written (for example because the
-- child has restricted its filesystem view), on stderr.
inChild :: String -> IO () -> IO Result
inChild label action = do
    pid <- getProcessID
    let logPath = "/tmp/openbsd-test-" ++ label ++ "-" ++ show pid ++ ".log"
    child <- forkProcess $ do
        outcome <- try action
        case outcome of
            Left (e :: SomeException) -> do
                logged <- try (writeFile logPath (displayException e))
                case logged of
                    Right () -> pure ()
                    Left (_ :: SomeException) ->
                        hPutStrLn stderr ("child failure: " ++ displayException e)
                exitImmediately (ExitFailure 1)
            Right () -> exitImmediately ExitSuccess
    status <- getProcessStatus True False child
    case status of
        Just (Exited ExitSuccess) -> pure Pass
        Just (Exited (ExitFailure _)) -> do
            logged <- try (readFile logPath)
            case logged of
                Right message -> pure (Fail message)
                Left (_ :: SomeException) ->
                    pure (Fail "<child failed; see stderr for details>")
        Just (Terminated signal _) ->
            pure (Fail ("child was terminated by signal " ++ show signal))
        _ -> pure (Fail "child vanished")

-- | Run an action in a forked child process that is expected to die
-- from the given signal.
expectSignal :: CInt -> IO () -> IO Result
expectSignal expected action = do
    child <- forkProcess $ do
        outcome <- try action
        case outcome of
            Left (_ :: SomeException) -> exitImmediately (ExitFailure 1)
            Right () -> exitImmediately ExitSuccess
    status <- getProcessStatus True False child
    case status of
        Just (Terminated signal _)
            | signal == expected -> pure Pass
            | otherwise -> pure (Fail ("expected signal " ++ show expected
                ++ ", got " ++ show signal))
        Just (Exited ExitSuccess) ->
            pure (Fail "child exited normally, expected a signal")
        Just (Exited (ExitFailure code)) ->
            pure (Fail ("child failed with exit code " ++ show code))
        _ -> pure (Fail "child vanished")

-- | Skip a test unless the current process is root.
requireRoot :: IO Result -> IO Result
requireRoot action = do
    rootEntry <- getUserEntryForName "root"
    euid <- getEffectiveUserID
    if euid == userID rootEntry
        then action
        else pure (Skip "requires root privileges")

-- Pure tests

promiseNamesTest :: IO Result
promiseNamesTest = do
    let names = map promiseName [minBound .. maxBound :: Promise]
        expected =
            [ "audio", "bpf", "chown", "cpath", "disklabel", "dns", "dpath"
            , "drm", "error", "exec", "fattr", "flock", "getpw", "id", "inet"
            , "mcast", "pf", "proc", "prot_exec", "ps", "recvfd", "route"
            , "rpath", "sendfd", "settime", "stdio", "tape", "tty", "unix"
            , "unveil", "video", "vminfo", "vmm", "wpath", "wroute"
            ]
    expect (names == expected && length (nub names) == length names
            && all (not . any (== ' ')) names)
        ("promise serialization mismatch: " ++ show names)

unveilPermissionsTest :: IO Result
unveilPermissionsTest =
    expect (permissionString [] == ""
            && permissionString [Read, Write, Execute, Create] == "rwxc"
            && permissionString [Create, Read] == "cr")
        "permission serialization mismatch"

-- Input validation tests (no kernel state involved)

nulRejectionTests :: [(String, IO Result)]
nulRejectionTests =
    [ ( "unveil: rejects embedded NUL bytes in paths"
      , expectIOError "unveil NUL" (unveil "/tmp\0etc" [Read]) )
    , ( "priv: rejects embedded NUL bytes in account names"
      , expectIOError "accountByName NUL" (accountByName "nobody\0root") )
    , ( "priv: rejects embedded NUL bytes in dropPrivileges"
      , expectIOError "dropPrivileges NUL" (dropPrivileges "nobody\0root") )
    , ( "priv: rejects embedded NUL bytes in initGroups"
      , expectIOError "initGroups NUL" (initGroups "nobody\0root" 0) )
    ]

-- pledge tests

-- | After pledging the empty promise set only @_exit(2)@ is allowed.
-- This test must not use 'exitImmediately' from the @unix@ package:
-- it calls @exit(3)@, whose atexit handlers write to stdio and would
-- be killed by the pledge.  A raw @_exit(2)@ is used instead.
pledgeEmptyTest :: IO Result
pledgeEmptyTest = do
    child <- forkProcess $ do
        result <- try (pledgeParts (Just []) Nothing)
        case result of
            Left (_ :: SomeException) -> c__exit 1
            Right () -> c__exit 0
    status <- getProcessStatus True False child
    case status of
        Just (Exited ExitSuccess) -> pure Pass
        Just (Exited (ExitFailure _)) -> pure (Fail "pledge \"\" was rejected")
        Just (Terminated signal _) ->
            pure (Fail ("child was terminated by signal " ++ show signal))
        _ -> pure (Fail "child vanished")

pledgeNullTest :: IO Result
pledgeNullTest = inChild "pledge-null" $ do
    pledge [Stdio]
    pledgeParts Nothing Nothing
    pledge [Stdio]
    pledgeBoth [Stdio] [Stdio]
    pledgeParts (Just [Stdio]) Nothing

-- | pledge(NULL, "") restricts exec promises to the empty set while
-- leaving the current promises unchanged; the process itself must
-- remain functional.
pledgeNullExecEmptyTest :: IO Result
pledgeNullExecEmptyTest = inChild "pledge-null-exec-empty" $ do
    pledge [Stdio]
    pledgeParts Nothing (Just [])
    void getProcessID
    pledge [Stdio]

pledgeIncreaseTest :: IO Result
pledgeIncreaseTest = inChild "pledge-increase" $ do
    pledge [Stdio]
    result <- try (pledge [Stdio, Rpath])
    case result of
        Left e | isPermissionError e -> pure ()
        Left e -> fail ("expected EPERM, got " ++ displayException e)
        Right () -> fail "promise increase was accepted"

pledgeExecIncreaseTest :: IO Result
pledgeExecIncreaseTest = inChild "pledge-exec-increase" $ do
    pledgeBoth [Stdio] [Stdio]
    result <- try (pledgeChild [Stdio, Rpath])
    case result of
        Left e | isPermissionError e -> pure ()
        Left e -> fail ("expected EPERM, got " ++ displayException e)
        Right () -> fail "exec promise increase was accepted"

pledgeViolationTest :: IO Result
pledgeViolationTest = expectSignal sigABRT $ do
    pledge []
    void getProcessID

-- unveil tests

unveilLockTest :: IO Result
unveilLockTest = inChild "unveil-lock" $ do
    unveilPaths [("/", [Read, Execute]), ("/tmp", [Read, Write, Create])]
    lockUnveil
    result <- try (unveil "/etc" [Read])
    case result of
        Left e | isPermissionError e -> pure ()
        Left e -> fail ("expected EPERM after locking, got " ++ displayException e)
        Right () -> fail "unveil succeeded after lockUnveil"

-- | unveil(2) resolves non-directory paths with namei in CREATE mode:
-- the final component may legitimately not exist (it is remembered by
-- name).  Only a nonexistent *directory* component fails with ENOENT.
unveilNonexistentTest :: IO Result
unveilNonexistentTest = inChild "unveil-enoent" $ do
    result <- try (unveil "/openbsd-test-dir-that-does-not-exist/file" [Read])
    case result of
        Left e | isDoesNotExistError e -> pure ()
        Left e -> fail ("expected ENOENT, got " ++ displayException e)
        Right () -> fail "path with nonexistent directory was unveiled"

unveilEnforcementTest :: IO Result
unveilEnforcementTest = inChild "unveil-enforcement" $ do
    unveilPaths [("/", [Read, Execute])]
    lockUnveil
    contents <- try (readFile "/dev/null") :: IO (Either IOException String)
    case contents of
        Left e -> fail ("reading /dev/null should succeed: " ++ displayException e)
        Right "" -> pure ()
        Right s -> fail ("unexpected /dev/null contents: " ++ show s)
    written <- try (writeFile "/tmp/openbsd-test-forbidden-file" "forbidden")
    case written of
        Left (_ :: IOException) -> pure ()
        Right () -> fail "writing /tmp succeeded under unveil / r x"

-- | The empty permission set unveils a path but permits no operation
-- on it.
unveilEmptyPermissionsTest :: IO Result
unveilEmptyPermissionsTest = inChild "unveil-empty-permissions" $ do
    unveil "/tmp" []
    lockUnveil
    result <- try (readFile "/dev/null") :: IO (Either IOException String)
    case result of
        Left (_ :: IOException) -> pure ()
        Right _ -> fail "empty permission set granted access"

-- privilege tests

accountResolutionTest :: IO Result
accountResolutionTest = do
    resolved <- try (accountByName "nobody") :: IO (Either IOException Account)
    missing <- lookupAccountByName "openbsd-test-no-such-user-xyz"
    case (resolved, missing) of
        (Left e, _) ->
            pure (Fail ("accountByName nobody failed: " ++ displayException e))
        (Right account, Nothing) ->
            expect (accountName account == "nobody") "unexpected account resolved"
        (Right _, Just _) -> pure (Fail "nonexistent user was resolved")

dropPrivilegesTest :: IO Result
dropPrivilegesTest = requireRoot $ inChild "privdrop" $ do
    account <- accountByName "nobody"
    rootEntry <- getUserEntryForName "root"
    dropPrivileges "nobody"
    rUid <- getResUserID
    rGid <- getResGroupID
    groups <- getGroups
    let uid = accountUid account
        gid = accountGid account
        rootUid = userID rootEntry
        rootGid = userGroupID rootEntry
    when (rUid /= (uid, uid, uid)) $
        fail ("uid mismatch after drop: " ++ show rUid)
    when (rGid /= (gid, gid, gid)) $
        fail ("gid mismatch after drop: " ++ show rGid)
    when (groups /= [gid]) $
        fail ("supplementary groups were not replaced: " ++ show groups)
    regainUid <- try (setResUserID rootUid rootUid rootUid)
    case regainUid of
        Left e | isPermissionError e -> pure ()
        Left e -> fail ("expected EPERM when regaining root uid, got " ++ displayException e)
        Right () -> fail "root uid was regained after the drop"
    regainGid <- try (setResGroupID rootGid rootGid rootGid)
    case regainGid of
        Left e | isPermissionError e -> pure ()
        Left e -> fail ("expected EPERM when regaining root gid, got " ++ displayException e)
        Right () -> fail "root gid was regained after the drop"

dropPrivilegesInitgroupsTest :: IO Result
dropPrivilegesInitgroupsTest = requireRoot $ inChild "privdrop-initgroups" $ do
    account <- accountByName "nobody"
    let gid = accountGid account
    dropPrivilegesWith Initgroups "nobody"
    rGid <- getResGroupID
    groups <- getGroups
    when (rGid /= (gid, gid, gid)) $
        fail ("gid mismatch after drop: " ++ show rGid)
    when (gid `notElem` groups) $
        fail ("primary gid missing from supplementary groups: " ++ show groups)

dropUnknownUserTest :: IO Result
dropUnknownUserTest = inChild "privdrop-unknown" $ do
    result <- try (dropPrivileges "openbsd-test-no-such-user-xyz")
    case result of
        Left (_ :: IOException) -> pure ()
        Right () -> fail "privileges were dropped to a nonexistent account"

-- | Without sufficient privileges the drop must fail early with the
-- native EPERM preserved through the masked transition, instead of
-- silently pretending to succeed.
dropUnprivilegedTest :: IO Result
dropUnprivilegedTest = inChild "privdrop-eperm" $ do
    account <- accountByName "nobody"
    let uid = accountUid account
    _ <- try (setResUserID uid uid uid) :: IO (Either IOException ())
    result <- try (dropPrivileges "nobody")
    case result of
        Left e | isPermissionError e -> pure ()
        Left e -> fail ("expected EPERM, got " ++ displayException e)
        Right () -> fail "dropPrivileges succeeded without privileges"

pledgeIdLifecycleTest :: IO Result
pledgeIdLifecycleTest = requireRoot $ inChild "pledge-id-lifecycle" $ do
    account <- accountByName "nobody"
    pledge [Stdio, Getpw, Id]
    dropPrivileges "nobody"
    pledge [Stdio]
    rUid <- getResUserID
    let uid = accountUid account
    when (rUid /= (uid, uid, uid)) $
        fail ("identity is wrong after drop: " ++ show rUid)

pureTests :: [(String, IO Result)]
pureTests =
    [ ("pledge: serializes every promise", promiseNamesTest)
    , ("unveil: serializes permission sets", unveilPermissionsTest)
    ] ++ nulRejectionTests

runtimeTests :: [(String, IO Result)]
runtimeTests =
    [ ("pledge: empty promise list restricts to _exit", pledgeEmptyTest)
    , ("pledge: NULL arguments change nothing", pledgeNullTest)
    , ("pledge: NULL promises with empty exec promises", pledgeNullExecEmptyTest)
    , ("pledge: promise increase fails with EPERM", pledgeIncreaseTest)
    , ("pledge: exec promise increase fails with EPERM", pledgeExecIncreaseTest)
    , ("pledge: violation aborts the process with SIGABRT", pledgeViolationTest)
    , ("unveil: rules can be installed and locked", unveilLockTest)
    , ("unveil: path with nonexistent directory fails with ENOENT", unveilNonexistentTest)
    , ("unveil: access outside the rules is denied", unveilEnforcementTest)
    , ("unveil: empty permission set grants nothing", unveilEmptyPermissionsTest)
    , ("priv: account resolution", accountResolutionTest)
    , ("priv: dropPrivileges fully drops identity (root)", dropPrivilegesTest)
    , ("priv: Initgroups policy (root)", dropPrivilegesInitgroupsTest)
    , ("priv: unknown user is reported", dropUnknownUserTest)
    , ("priv: dropPrivileges fails with EPERM without privileges", dropUnprivilegedTest)
    , ("priv: id promise can be removed after dropping (root)", pledgeIdLifecycleTest)
    ]

tests :: [(String, IO Result)]
tests = pureTests ++ runtimeTests

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
#if defined(openbsd_HOST_OS)
    ok <- runTests tests
#else
    putStrLn ("Not running on OpenBSD: running " ++ show (length pureTests)
        ++ " of " ++ show (length tests) ++ " tests (runtime tests skipped).")
    ok <- runTests pureTests
#endif
    unless ok (exitWith (ExitFailure 1))
