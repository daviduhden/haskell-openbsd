{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Main
-- Description : Test suite for the openbsd package
--
-- Pure tests (promise\/permission serialization) run everywhere.
-- Runtime tests exercise the real kernel interfaces and must run on
-- OpenBSD; tests that require root are skipped cleanly otherwise.
--
-- All runtime tests run in forked child processes so that the test
-- runner itself never loses privileges or has its authority restricted.
module Main (main) where

import Control.Exception (IOException, SomeException, displayException, try)
import Control.Monad (unless, void, when)
import Data.List (nub)
import Foreign.C.Types (CInt)
import System.Exit (ExitCode(..), exitWith)
import System.IO (BufferMode(..), hSetBuffering, stdout)
import System.IO.Error (isDoesNotExistError, isPermissionError)
import System.Posix.Process (ProcessStatus(..), exitImmediately, forkProcess,
                             getProcessID, getProcessStatus)
import System.Posix.Signals (sigABRT)
import System.Posix.User (getEffectiveUserID, getGroups, getUserEntryForName,
                          userID)

import System.OpenBSD

data Result = Pass | Skip String | Fail String

expect :: Bool -> String -> IO Result
expect condition reason = pure (if condition then Pass else Fail reason)

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
-- success via its exit status; failures carry a message in a log file.
inChild :: String -> IO () -> IO Result
inChild label action = do
    pid <- getProcessID
    let logPath = "/tmp/openbsd-test-" ++ label ++ "-" ++ show pid ++ ".log"
    child <- forkProcess $ do
        outcome <- try action
        case outcome of
            Left (e :: SomeException) -> do
                writeFile logPath (displayException e)
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
                    pure (Fail "<child failed without a log message>")
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

-- pledge tests

pledgeEmptyTest :: IO Result
pledgeEmptyTest = inChild "pledge-empty" $
    pledgeRaw (Just []) Nothing

pledgeNullTest :: IO Result
pledgeNullTest = inChild "pledge-null" $ do
    pledge [Stdio]
    pledgeRaw Nothing Nothing
    pledge [Stdio]
    pledgeBoth [Stdio] [Stdio]
    pledgeRaw (Just [Stdio]) Nothing

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

unveilNonexistentTest :: IO Result
unveilNonexistentTest = inChild "unveil-enoent" $ do
    result <- try (unveil "/openbsd-test-path-that-does-not-exist" [Read])
    case result of
        Left e | isDoesNotExistError e -> pure ()
        Left e -> fail ("expected ENOENT, got " ++ displayException e)
        Right () -> fail "nonexistent path was unveiled"

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

-- privilege tests

accountResolutionTest :: IO Result
accountResolutionTest = do
    entry <- try (accountByName "nobody") :: IO (Either IOException Account)
    missing <- try (accountByName "openbsd-test-no-such-user-xyz")
        :: IO (Either IOException Account)
    case (entry, missing) of
        (Right e, Left _) ->
            expect (accountName e == "nobody") "unexpected account resolved"
        (Left e, _) ->
            pure (Fail ("accountByName nobody failed: " ++ displayException e))
        (_, Right _) -> pure (Fail "nonexistent user was resolved")

dropPrivilegesTest :: IO Result
dropPrivilegesTest = requireRoot $ inChild "privdrop" $ do
    account <- accountByName "nobody"
    rootEntry <- getUserEntryForName "root"
    dropPrivileges "nobody"
    rUid <- getResUid
    rGid <- getResGid
    groups <- getGroups
    let uid = accountUid account
        gid = accountGid account
    when (rUid /= (uid, uid, uid)) $
        fail ("uid mismatch after drop: " ++ show rUid)
    when (rGid /= (gid, gid, gid)) $
        fail ("gid mismatch after drop: " ++ show rGid)
    when (groups /= [gid]) $
        fail ("supplementary groups were not replaced: " ++ show groups)
    regain <- try (setResUid (userID rootEntry) (userID rootEntry) (userID rootEntry))
    case regain of
        Left e | isPermissionError e -> pure ()
        Left e -> fail ("expected EPERM when regaining root, got " ++ displayException e)
        Right () -> fail "root privileges were regained after the drop"

dropPrivilegesInitgroupsTest :: IO Result
dropPrivilegesInitgroupsTest = requireRoot $ inChild "privdrop-initgroups" $ do
    account <- accountByName "nobody"
    let gid = accountGid account
    dropPrivilegesWith Initgroups "nobody"
    rGid <- getResGid
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

pledgeIdLifecycleTest :: IO Result
pledgeIdLifecycleTest = requireRoot $ inChild "pledge-id-lifecycle" $ do
    account <- accountByName "nobody"
    pledge [Stdio, Getpw, Id]
    dropPrivileges "nobody"
    pledge [Stdio]
    rUid <- getResUid
    let uid = accountUid account
    when (rUid /= (uid, uid, uid)) $
        fail ("identity is wrong after drop: " ++ show rUid)

pureTests :: [(String, IO Result)]
pureTests =
    [ ("pledge: serializes every promise", promiseNamesTest)
    , ("unveil: serializes permission sets", unveilPermissionsTest)
    ]

runtimeTests :: [(String, IO Result)]
runtimeTests =
    [ ("pledge: empty promise list restricts to _exit", pledgeEmptyTest)
    , ("pledge: NULL arguments change nothing", pledgeNullTest)
    , ("pledge: promise increase fails with EPERM", pledgeIncreaseTest)
    , ("pledge: exec promise increase fails with EPERM", pledgeExecIncreaseTest)
    , ("pledge: violation aborts the process with SIGABRT", pledgeViolationTest)
    , ("unveil: rules can be installed and locked", unveilLockTest)
    , ("unveil: nonexistent path fails with ENOENT", unveilNonexistentTest)
    , ("unveil: access outside the rules is denied", unveilEnforcementTest)
    , ("priv: account resolution", accountResolutionTest)
    , ("priv: dropPrivileges fully drops identity (root)", dropPrivilegesTest)
    , ("priv: Initgroups policy (root)", dropPrivilegesInitgroupsTest)
    , ("priv: unknown user is reported", dropUnknownUserTest)
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
