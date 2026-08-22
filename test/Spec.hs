{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Main
-- Description : Test suite for the openbsd package
--
-- Pure tests (serialization, NUL rejection) run everywhere.  Runtime
-- tests exercise the real kernel interfaces and must run on OpenBSD;
-- tests that require root are skipped cleanly otherwise.
--
-- All runtime tests run in forked child processes so that the test
-- runner itself never loses privileges, changes its filesystem root,
-- or has its authority restricted, and so that no test depends on the
-- execution order of any other test.  The suite is built with
-- @-threaded@ so that daemonization and fork behavior are exercised
-- against the threaded runtime.
module Main (main) where

import Control.Exception (IOException, SomeException, displayException,
                             evaluate, try)
import Control.Monad (forM_, unless, void, when)
import Data.List (isInfixOf, nub)
import Foreign.C.Types (CInt(..))
import System.Directory (createDirectoryIfMissing,
                         doesDirectoryExist, doesFileExist,
                         getCurrentDirectory, removeDirectory, removeFile)
import System.Environment (getArgs)
import System.Exit (ExitCode(..), exitWith)
import System.IO (BufferMode(..), IOMode(..), hClose, hFlush, hGetContents,
                  hGetLine, hPutChar, hPutStrLn, hSetBuffering,
                  hSetBinaryMode, openFile, stderr, stdout)
import System.IO.Error (isDoesNotExistError, isPermissionError)
import System.Posix.Files (groupExecuteMode, groupReadMode,
                           otherExecuteMode, otherReadMode, ownerExecuteMode,
                           ownerReadMode, ownerWriteMode, setFileMode,
                           setOwnerAndGroup, setUserIDMode, unionFileModes)
import System.Posix.Directory (changeWorkingDirectory)
import System.Posix.IO (closeFd, createPipe, dup, dupTo, fdToHandle,
                        handleToFd, stdError, stdInput, stdOutput)
import System.Posix.Process (ProcessStatus(..), executeFile, exitImmediately,
                             forkProcess, getProcessGroupID, getProcessID,
                             getProcessStatus)
import System.Posix.Signals (sigABRT)
import System.Posix.Types (Fd(..), FileMode)
import System.Posix.User (getEffectiveGroupID, getEffectiveUserID, getGroups,
                          getUserEntryForName, userGroupID, userID)
import System.Timeout (timeout)
import Foreign.C.Error (throwErrno)
import Foreign.Marshal.Array (allocaArray)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peekElemOff)
import qualified Data.ByteString as BS

import System.OpenBSD

foreign import ccall unsafe "unistd.h _exit"
    c__exit :: CInt -> IO ()

-- Provided by the library's cbits: pledge("") followed by _exit(2)
-- with no Haskell code in between.
foreign import ccall unsafe "hs_pledge_empty_then_exit"
    c_hsPledgeEmptyThenExit :: IO ()

-- AF_UNIX and SOCK_STREAM are pinned at 1 by the OpenBSD ABI
-- (see socket(2)); the test suite binds socketpair(2) itself rather
-- than depending on the socket API of the installed unix package,
-- which changed across unix releases.
foreign import ccall unsafe "sys/socket.h socketpair"
    c_socketpair :: CInt -> CInt -> CInt -> Ptr CInt -> IO CInt

afUnix, sockStream :: CInt
afUnix = 1
sockStream = 1

socketPair :: IO (Fd, Fd)
socketPair = allocaArray 2 $ \sockets -> do
    result <- c_socketpair afUnix sockStream 0 sockets
    when (result /= 0) (throwErrno "socketpair")
    (,) <$> (Fd <$> peekElemOff sockets 0) <*> (Fd <$> peekElemOff sockets 1)

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
                        hFlush stdout
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

-- | Fork a child that execs @prog@ with @args@, capturing its stdout.
captureOutput :: FilePath -> [String] -> IO (Either String String)
captureOutput prog args = do
    (readFd, writeFd) <- createPipe
    child <- forkProcess $ do
        closeFd readFd
        _ <- dupTo writeFd stdOutput
        closeFd writeFd
        _ <- executeFile prog True args Nothing
        exitImmediately (ExitFailure 127)
    closeFd writeFd
    output <- timeout 60000000 $ do
        h <- fdToHandle readFd
        hSetBinaryMode h True
        s <- hGetContents h
        _ <- evaluate (length s)
        pure s
    status <- getProcessStatus True False child
    closeFd readFd
    case output of
        Nothing -> pure (Left "timed out reading child output")
        Just out -> case status of
            Just (Exited ExitSuccess) -> pure (Right out)
            _ -> pure (Left ("child failed: " ++ show status ++ ", output: " ++ out))

-- | Skip a test unless the current process is root.
requireRoot :: IO Result -> IO Result
requireRoot action = do
    rootEntry <- getUserEntryForName "root"
    euid <- getEffectiveUserID
    if euid == userID rootEntry
        then action
        else pure (Skip "requires root privileges")

-- | Build a tiny C probe that prints issetugid(2), using the
-- base-system compiler.  This avoids depending on how the test
-- executable was invoked (argv[0] is not reliable under cabal test).
issetugidProbeFixture :: IO FilePath
issetugidProbeFixture = do
    let cPath = "/tmp/openbsd-issetugid-probe.c"
        binPath = "/tmp/openbsd-issetugid-probe"
    writeFile cPath (unlines
        [ "#include <stdio.h>"
        , "#include <unistd.h>"
        , "int"
        , "main(void)"
        , "{"
        , "    printf(\"%d\\n\", issetugid());"
        , "    return 0;"
        , "}"
        ])
    compiled <- captureOutput "/usr/bin/cc" ["-o", binPath, cPath]
    removeFile cPath
    case compiled of
        Left e -> fail ("cc failed: " ++ e)
        Right _ -> pure ()
    pure binPath

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
    , ( "chroot: rejects embedded NUL bytes in paths"
      , expectIOError "chroot NUL" (chroot "/tmp\0etc") )
    , ( "chroot: enterChroot rejects embedded NUL bytes"
      , expectIOError "enterChroot NUL" (enterChroot "/tmp\0etc") )
    , ( "proc: rejects embedded NUL bytes in process titles"
      , expectIOError "setProcessTitle NUL" (setProcessTitle "a\0b") )
    , ( "random: rejects negative buffer lengths"
      , expectIOError "arc4RandomBytes negative" (arc4RandomBytes (-1)) )
    ]

-- pledge tests

-- | After pledging the empty promise set only @_exit(2)@ is allowed.
-- This test must not use 'exitImmediately' from the @unix@ package:
-- it calls @exit(3)@, whose atexit handlers write to stdio and would
-- be killed by the pledge.  A raw @_exit(2)@ is used instead.
pledgeEmptyTest :: IO Result
pledgeEmptyTest = do
    child <- forkProcess $ do
        c_hsPledgeEmptyThenExit
        c__exit 1
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

-- chroot tests

-- | Deterministic in both the privileged and unprivileged phases: the
-- child makes itself unprivileged first if necessary, then chroot
-- must fail with EPERM.
chrootEpermTest :: IO Result
chrootEpermTest = inChild "chroot-eperm" $ do
    account <- accountByName "nobody"
    let uid = accountUid account
    _ <- try (setResUserID uid uid uid) :: IO (Either IOException ())
    result <- try (chroot "/")
    case result of
        Left e | isPermissionError e -> pure ()
        Left e -> fail ("expected EPERM, got " ++ displayException e)
        Right () -> fail "chroot succeeded without privileges"

enterChrootTest :: IO Result
enterChrootTest = requireRoot $ do
    let rootDir = "/tmp/openbsd-enterchroot-test"
    createDirectoryIfMissing True rootDir
    writeFile (rootDir ++ "/marker") "inside"
    result <- inChild "enterchroot" $ do
        enterChroot rootDir
        cwd <- getCurrentDirectory
        when (cwd /= "/") (fail ("cwd is " ++ show cwd ++ ", expected /"))
        visible <- doesFileExist "/marker"
        when (not visible) (fail "marker not visible inside the new root")
        outside <- doesDirectoryExist "/etc"
        when outside (fail "/etc visible inside the new root")
        changeWorkingDirectory ".."
        cwd2 <- getCurrentDirectory
        when (cwd2 /= "/") (fail "escaped the new root via '..'")
    removeFile (rootDir ++ "/marker")
    removeDirectory rootDir
    pure result

-- credential tests

issetugidPlainTest :: IO Result
issetugidPlainTest = inChild "issetugid-false" $ do
    tainted <- isSetugid
    when tainted (fail "untainted process reports issetugid")

-- | A plain exec of a non-set-ID binary must leave the process
-- untainted.
issetugidPlainExecTest :: IO Result
issetugidPlainExecTest = do
    probe <- issetugidProbeFixture
    output <- captureOutput probe []
    removeFile probe
    case output of
        Left e -> pure (Fail ("probe failed: " ++ e))
        Right s -> expect (s == "0\n")
            ("plain exec reported taint, got: " ++ show s)

-- | A set-ID exec must taint the process: the kernel sets the flag
-- whenever the executed file carries the set-ID bits.
issetugidSuidExecTest :: IO Result
issetugidSuidExecTest = requireRoot $ do
    probe <- issetugidProbeFixture
    rootEntry <- getUserEntryForName "root"
    let suidMode :: FileMode
        suidMode = foldl1 unionFileModes
            [ ownerReadMode, ownerWriteMode, ownerExecuteMode
            , groupReadMode, groupExecuteMode
            , otherReadMode, otherExecuteMode
            , setUserIDMode ]
    setOwnerAndGroup probe (userID rootEntry) (userGroupID rootEntry)
    setFileMode probe suidMode
    output <- captureOutput probe []
    removeFile probe
    case output of
        Left e -> pure (Fail ("probe failed: " ++ e))
        Right s -> expect (s == "1\n")
            ("set-ID exec not detected, got: " ++ show s)

getpeereidTest :: IO Result
getpeereidTest = inChild "getpeereid" $ do
    (a, b) <- socketPair
    (uid, gid) <- getPeerCredentials a
    euid <- getEffectiveUserID
    egid <- getEffectiveGroupID
    closeFd a
    closeFd b
    when (uid /= euid || gid /= egid) $
        fail ("peer credentials mismatch: " ++ show (uid, gid)
            ++ " vs " ++ show (euid, egid))

getpeereidBadFdTest :: IO Result
getpeereidBadFdTest = inChild "getpeereid-badfd" $ do
    result <- try (getPeerCredentials (Fd 99999))
    case result of
        Left (_ :: IOException) -> pure ()
        Right _ -> fail "getpeereid succeeded on an invalid descriptor"

getpeereidNotSockTest :: IO Result
getpeereidNotSockTest = inChild "getpeereid-notsock" $ do
    nullHandle <- openFile "/dev/null" ReadMode
    fd <- handleToFd nullHandle
    result <- try (getPeerCredentials fd)
    closeFd fd
    hClose nullHandle
    case result of
        Left (_ :: IOException) -> pure ()
        Right _ -> fail "getpeereid succeeded on a regular file"

-- process-title tests

setproctitleObservableTest :: IO Result
setproctitleObservableTest = do
    (controlRead, controlWrite) <- createPipe
    (outputRead, outputWrite) <- createPipe
    let marker = "obd-title-%s-%n-%x"
    child <- forkProcess $ do
        closeFd controlWrite
        closeFd outputRead
        _ <- dupTo controlRead stdInput
        _ <- dupTo outputWrite stdOutput
        hSetBuffering stdout LineBuffering
        setProcessTitle marker
        putStrLn "ready"
        hFlush stdout
        _ <- getChar
        resetProcessTitle
        putStrLn "ready"
        hFlush stdout
        _ <- getChar
        exitImmediately ExitSuccess
    closeFd controlRead
    closeFd outputWrite
    outHandle <- fdToHandle outputRead
    controlHandle <- fdToHandle controlWrite
    hSetBuffering controlHandle LineBuffering
    first <- timeout 60000000 (hGetLine outHandle)
    case first of
        Nothing -> pure (Fail "child did not signal readiness")
        Just "ready" -> do
            withTitle <- captureOutput "/bin/ps" ["-ww", "-p", show child, "-o", "command"]
            hPutChar controlHandle 'x'
            hFlush controlHandle
            second <- timeout 60000000 (hGetLine outHandle)
            case second of
                Nothing -> pure (Fail "child did not signal reset")
                Just "ready" -> do
                    resetTitle <- captureOutput "/bin/ps" ["-ww", "-p", show child, "-o", "command"]
                    hPutChar controlHandle 'x'
                    hFlush controlHandle
                    _ <- getProcessStatus True False child
                    closeFd outputRead
                    closeFd controlWrite
                    pure $ case withTitle of
                        Left e -> Fail e
                        Right out
                            | not (marker `isInfixOf` out) ->
                                Fail ("ps did not show the title: " ++ show out)
                            | otherwise -> case resetTitle of
                                Left e -> Fail e
                                Right out2
                                    | marker `isInfixOf` out2 ->
                                        Fail ("title not reset: " ++ show out2)
                                    | otherwise -> Pass
                Just other -> pure (Fail ("unexpected child signal: " ++ show other))
        Just other -> pure (Fail ("unexpected child signal: " ++ show other))

-- random tests

arc4randomTest :: IO Result
arc4randomTest = inChild "arc4random" $ do
    b0 <- arc4RandomBytes 0
    when (BS.length b0 /= 0) (fail "zero-length request returned data")
    b1 <- arc4RandomBytes 1
    when (BS.length b1 /= 1) (fail "one-byte request returned wrong length")
    b4096 <- arc4RandomBytes 4096
    when (BS.length b4096 /= 4096) (fail "4096-byte request returned wrong length")
    _ <- arc4Random
    pure ()

arc4randomUniformTest :: IO Result
arc4randomUniformTest = inChild "arc4random-uniform" $ do
    zero <- arc4RandomUniform 0
    when (zero /= 0) (fail "arc4random_uniform(0) returned a nonzero value")
    one <- arc4RandomUniform 1
    when (one /= 0) (fail "arc4random_uniform(1) returned a nonzero value")
    forM_ [1 .. 50 :: Int] $ \_ -> do
        value <- arc4RandomUniform 1000
        when (value >= 1000) (fail "uniform result out of bounds")

-- | The arc4random family must work under pledge stdio: it only
-- requires getentropy(2), which is part of the stdio promise.
arc4randomPledgeTest :: IO Result
arc4randomPledgeTest = inChild "arc4random-pledge" $ do
    pledge [Stdio]
    _ <- arc4Random
    buf <- arc4RandomBytes 64
    when (BS.length buf /= 64) (fail "wrong buffer length under pledge")
    _ <- arc4RandomUniform 10
    pure ()

-- daemonization tests

sessionCheck :: IO Bool
sessionCheck = (==) <$> getProcessGroupID <*> getProcessID

cwdCheck :: FilePath -> IO Bool
cwdCheck expected = (== expected) <$> getCurrentDirectory

-- | Standard descriptors are considered open when dup(2) succeeds
-- on each of them.  This probes the raw descriptors directly,
-- without involving the RTS IO manager (whose state after nested
-- forks is not the point of this test).
stdFdsOpenCheck :: IO [Bool]
stdFdsOpenCheck = mapM checkFdOpen [stdInput, stdOutput, stdError]

checkFdOpen :: Fd -> IO Bool
checkFdOpen fd = do
    result <- try (dup fd) :: IO (Either IOException Fd)
    case result of
        Left _ -> pure False
        Right duped -> closeFd duped >> pure True

-- | The daemonized child reports via an inherited pipe; the original
-- process exits inside 'daemonize', exactly like daemon(3).
daemonizeTest :: IO Result
daemonizeTest = do
    (readFd, writeFd) <- createPipe
    helper <- forkProcess $ do
        closeFd readFd
        report <- fdToHandle writeFd
        hSetBuffering report LineBuffering
        daemonize $ do
            ok1 <- sessionCheck
            ok2 <- cwdCheck "/"
            fds <- stdFdsOpenCheck
            hPutStrLn report ("checks " ++ show ([ok1, ok2] ++ fds))
            hFlush report
    closeFd writeFd
    output <- timeout 60000000 $ do
        h <- fdToHandle readFd
        s <- hGetContents h
        _ <- evaluate (length s)
        pure s
    status <- getProcessStatus True False helper
    case (output, status) of
        (Nothing, _) -> pure (Fail "timed out waiting for the daemonized child")
        (_, Just (Exited ExitSuccess)) ->
            expect (output == Just "checks [True,True,True,True,True]\n")
                ("unexpected daemon report: " ++ show output)
        _ -> pure (Fail ("daemonize helper failed: " ++ show status))

daemonizePreserveTest :: IO Result
daemonizePreserveTest = do
    originalCwd <- getCurrentDirectory
    (readFd, writeFd) <- createPipe
    helper <- forkProcess $ do
        closeFd readFd
        report <- fdToHandle writeFd
        hSetBuffering report LineBuffering
        daemonizeWith defaultDaemonOptions
            { changeDirectoryToRoot = False
            , redirectStandardStreams = False
            } $ do
            ok1 <- sessionCheck
            ok2 <- cwdCheck originalCwd
            fds <- stdFdsOpenCheck
            hPutStrLn report ("checks " ++ show ([ok1, ok2] ++ fds))
            hFlush report
    closeFd writeFd
    output <- timeout 60000000 $ do
        h <- fdToHandle readFd
        s <- hGetContents h
        _ <- evaluate (length s)
        pure s
    status <- getProcessStatus True False helper
    case (output, status) of
        (Nothing, _) -> pure (Fail "timed out waiting for the daemonized child")
        (_, Just (Exited ExitSuccess)) ->
            expect (output == Just "checks [True,True,True,True,True]\n")
                ("unexpected daemon report: " ++ show output)
        _ -> pure (Fail ("daemonize helper failed: " ++ show status))

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
    , ("chroot: chroot fails with EPERM without privileges", chrootEpermTest)
    , ("chroot: enterChroot confines the process (root)", enterChrootTest)
    , ("cred: plain fork is not set-ID tainted", issetugidPlainTest)
    , ("cred: plain exec is not set-ID tainted", issetugidPlainExecTest)
    , ("cred: set-ID exec taints the process (root)", issetugidSuidExecTest)
    , ("cred: getpeereid returns peer credentials", getpeereidTest)
    , ("cred: getpeereid fails on an invalid descriptor", getpeereidBadFdTest)
    , ("cred: getpeereid fails on a regular file", getpeereidNotSockTest)
    , ("proc: setproctitle is observable via ps(1)", setproctitleObservableTest)
    , ("random: arc4random buffer lengths", arc4randomTest)
    , ("random: arc4random_uniform stays in bounds", arc4randomUniformTest)
    , ("random: arc4random works under pledge stdio", arc4randomPledgeTest)
    , ("proc: daemonize detaches the process", daemonizeTest)
    , ("proc: daemonize can preserve cwd and streams", daemonizePreserveTest)
    ]

tests :: [(String, IO Result)]
tests = pureTests ++ runtimeTests

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    args <- getArgs
    case args of
        "--issetugid-probe" : _ -> do
            tainted <- isSetugid
            putStrLn (if tainted then "1" else "0")
            hFlush stdout
            exitWith ExitSuccess
        _ -> do
#if defined(openbsd_HOST_OS)
            ok <- runTests tests
#else
            putStrLn ("Not running on OpenBSD: running " ++ show (length pureTests)
                ++ " of " ++ show (length tests) ++ " tests (runtime tests skipped).")
            ok <- runTests pureTests
#endif
            unless ok (exitWith (ExitFailure 1))
