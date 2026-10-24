{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Main
Description : Test suite for the openbsd package

Pure tests (serialization, NUL rejection) run everywhere.  Runtime
tests exercise the real kernel interfaces and must run on OpenBSD;
tests that require root are skipped cleanly otherwise.

Most runtime tests run in forked child processes so that the test
runner itself never loses privileges, changes its filesystem root,
or has its authority restricted, and so that no test depends on the
execution order of any other test.  Account resolution, the native C
probes, and the manual fork-based checks (titles, closefrom,
daemonization, and the set-ID exec probe) run in the runner or in a
dedicated child.  The suite is built with @-threaded@ so that
daemonization and fork behavior are exercised against the threaded
runtime.
-}
module Main (main) where

import Control.Exception (
    IOException,
    SomeException,
    bracket,
    displayException,
    evaluate,
    finally,
    onException,
    try,
 )
import Control.Monad (forM, forM_, unless, void, when)
import Data.Bits ((.|.))
import Data.ByteString qualified as BS
import Data.List (isInfixOf, nub)
import Data.Word (Word8)
import Foreign.C.Error (Errno (..), eBADF, eINVAL, eNOENT, ePERM, throwErrno)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (free, mallocBytes)
import Foreign.Marshal.Array (allocaArray, peekArray)
import Foreign.Ptr (Ptr, castPtr, intPtrToPtr, nullPtr)
import Foreign.Storable (peek, peekElemOff, pokeByteOff)
import GHC.IO.Exception qualified as IOE
import System.Directory (
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    getCurrentDirectory,
    getDirectoryContents,
    removeDirectory,
    removeFile,
 )
import System.Exit (ExitCode (..), exitWith)
import System.IO (
    BufferMode (..),
    IOMode (..),
    hClose,
    hFlush,
    hGetContents,
    hGetLine,
    hPutChar,
    hPutStrLn,
    hSetBinaryMode,
    hSetBuffering,
    openFile,
    stderr,
    stdout,
 )
import System.Posix.Directory (changeWorkingDirectory)
import System.Posix.IO (
    closeFd,
    createPipe,
    dup,
    dupTo,
    fdToHandle,
    handleToFd,
    stdError,
    stdInput,
    stdOutput,
 )
import System.Posix.Process (
    ProcessStatus (..),
    executeFile,
    exitImmediately,
    forkProcess,
    getProcessGroupID,
    getProcessID,
    getProcessStatus,
 )
import System.Posix.Signals (sigABRT, sigKILL, signalProcess)
import System.Posix.Types (COff (..), Fd (..), ProcessID)
import System.Posix.User (
    getEffectiveGroupID,
    getEffectiveUserID,
    getGroups,
    getUserEntryForName,
    userGroupID,
    userID,
 )
import System.Timeout (timeout)

import System.OpenBSD

foreign import ccall unsafe "unistd.h _exit"
    c__exit :: CInt -> IO ()

-- AF_UNIX and SOCK_STREAM are pinned at 1 by the OpenBSD ABI
-- (see socket(2)); the test suite binds socketpair(2) itself rather
-- than depending on the socket API of the installed unix package,
-- which changed across unix releases.
foreign import ccall unsafe "sys/socket.h socketpair"
    c_socketpair :: CInt -> CInt -> CInt -> Ptr CInt -> IO CInt

-- mmap/mprotect/munmap for the mimmutable test, operating on a page
-- mapped by the test itself.  The final argument is off_t (64-bit on
-- OpenBSD), not CInt.
foreign import ccall unsafe "sys/mman.h mmap"
    c_mmap :: Ptr () -> CSize -> CInt -> CInt -> CInt -> COff -> IO (Ptr ())

foreign import ccall unsafe "sys/mman.h mimmutable"
    c_mimmutable :: Ptr () -> CSize -> IO CInt

foreign import ccall unsafe "sys/mman.h mprotect"
    c_mprotect :: Ptr () -> CSize -> CInt -> IO CInt

foreign import ccall unsafe "sys/mman.h munmap"
    c_munmap :: Ptr () -> CSize -> IO CInt

protReadWrite, protRead, mapAnon, mapPrivate :: CInt
protReadWrite = 3
protRead = 1
mapAnon = 0x1000
mapPrivate = 0x0002

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

{- | Require an action to fail with a specific native @errno@.  This is
stricter than 'isPermissionError', which accepts both @EACCES@ and
@EPERM@, and keeps tests whose names promise @EPERM@ honest.
-}
assertErrno :: Errno -> String -> IO a -> IO ()
assertErrno expected context action = do
    result <- try action
    case result of
        Left (e :: IOException) ->
            case IOE.ioe_errno e of
                Just c
                    | Errno c == expected -> pure ()
                other ->
                    fail
                        ( context
                            ++ ": expected "
                            ++ show expected
                            ++ ", got "
                            ++ displayException e
                            ++ " (errno "
                            ++ show other
                            ++ ")"
                        )
        Right _ ->
            fail
                ( context
                    ++ ": expected "
                    ++ show expected
                    ++ ", but the call succeeded"
                )

-- | Ignore an I/O error from cleanup, without hiding the test result.
ignoreIOException :: IO () -> IO ()
ignoreIOException action = do
    _ <- try action :: IO (Either IOException ())
    pure ()

{- | Wait for a child, but do not let a stuck child hang the whole
suite.  On timeout, send @SIGKILL@ and reap it; the caller then sees a
signal termination (or 'Nothing' if even the kill/reap fails).
-}
waitForProcess :: ProcessID -> IO (Maybe ProcessStatus)
waitForProcess child = do
    result <- timeout 60000000 (getProcessStatus True False child)
    case result of
        Just status -> pure status
        Nothing -> do
            _ <- try (signalProcess sigKILL child) :: IO (Either IOException ())
            killed <- timeout 5000000 (getProcessStatus True False child)
            case killed of
                Just status -> pure status
                Nothing -> pure Nothing

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

{- | Run an action in a forked child process.  The child reports
success via its exit status; failures carry a message in a log file
or, if the log file cannot be written (for example because the
child has restricted its filesystem view), on stderr.
-}
inChild :: String -> IO () -> IO Result
inChild label action = do
    pid <- getProcessID
    let logPath = "/tmp/openbsd-test-" ++ label ++ "-" ++ show pid ++ ".log"
    -- Remove a stale log from an earlier process with a recycled PID.
    ignoreIOException (removeFile logPath)
    child <- forkProcess $ do
        outcome <- try action
        case outcome of
            Left (e :: SomeException) -> do
                logged <- try (writeFile logPath (displayException e))
                case logged of
                    Right () -> pure ()
                    Left (_ :: SomeException) -> do
                        hPutStrLn stderr (displayException e)
                        hFlush stderr
                exitImmediately (ExitFailure 1)
            Right () -> exitImmediately ExitSuccess
    status <- waitForProcess child
    case status of
        Just (Exited ExitSuccess) -> pure Pass
        Just (Exited (ExitFailure _)) -> do
            logged <- try $ do
                message <- readFile logPath
                _ <- evaluate (length message)
                pure message
            ignoreIOException (removeFile logPath)
            case logged of
                Right message -> pure (Fail message)
                Left (_ :: SomeException) ->
                    pure (Fail "<child failed; see stderr for details>")
        Just (Terminated signal _) -> do
            ignoreIOException (removeFile logPath)
            pure (Fail ("child was terminated by signal " ++ show signal))
        _ -> do
            ignoreIOException (removeFile logPath)
            pure (Fail "child vanished")

{- | Run an action in a forked child process that is expected to die
from the given signal.
-}
expectSignal :: CInt -> IO () -> IO Result
expectSignal expected action = do
    child <- forkProcess $ do
        outcome <- try action
        case outcome of
            Left (_ :: SomeException) -> exitImmediately (ExitFailure 1)
            Right () -> exitImmediately ExitSuccess
    status <- waitForProcess child
    case status of
        Just (Terminated signal _)
            | signal == expected -> pure Pass
            | otherwise ->
                pure
                    ( Fail
                        ( "expected signal "
                            ++ show expected
                            ++ ", got "
                            ++ show signal
                        )
                    )
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
        _ <- dupTo writeFd stdError
        closeFd writeFd
        _ <- executeFile prog True args Nothing
        exitImmediately (ExitFailure 127)
    closeFd writeFd
    output <- timeout 60000000 $
        bracket (fdToHandle readFd) hClose $ \h -> do
            hSetBinaryMode h True
            s <- hGetContents h
            _ <- evaluate (length s)
            pure s
    status <- waitForProcess child
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

{- | Build a tiny C probe that prints issetugid(2), using the
base-system compiler.  This avoids depending on how the test
executable was invoked (argv[0] is not reliable under cabal test).
-}
issetugidProbeFixture :: IO FilePath
issetugidProbeFixture = do
    pid <- getProcessID
    let cPath = "/tmp/openbsd-issetugid-probe-" ++ show pid ++ ".c"
        binPath = "/tmp/openbsd-issetugid-probe-" ++ show pid
    writeFile
        cPath
        ( unlines
            [ "#include <stdio.h>"
            , "#include <unistd.h>"
            , "int"
            , "main(void)"
            , "{"
            , "    printf(\"%d\\n\", issetugid());"
            , "    return 0;"
            , "}"
            ]
        )
    compiled <-
        captureOutput
            "/usr/bin/cc"
            ["-std=c23", "-Wall", "-Wextra", "-Werror", "-o", binPath, cPath]
            `finally` ignoreIOException (removeFile cPath)
    case compiled of
        Left e -> fail ("cc failed: " ++ e)
        Right _ -> pure ()
    pure binPath

-- Pure tests

promiseNamesTest :: IO Result
promiseNamesTest = do
    let names = map promiseName [minBound .. maxBound :: Promise]
        expected =
            [ "audio"
            , "bpf"
            , "chown"
            , "cpath"
            , "disklabel"
            , "dns"
            , "dpath"
            , "drm"
#ifndef OPENBSD_80
            , "error"
            , "exec"
#endif
            , "fattr"
            , "flock"
            , "getpw"
            , "id"
            , "inet"
            , "mcast"
            , "pf"
            , "proc"
            , "prot_exec"
            , "ps"
            , "recvfd"
            , "route"
            , "rpath"
            , "sendfd"
            , "settime"
            , "stdio"
            , "tape"
            , "tty"
            , "unix"
            , "unveil"
            , "video"
            , "vminfo"
            , "vmm"
            , "wpath"
            , "wroute"
            ]
    expect
        ( names == expected
            && length (nub names) == length names
            && all (not . any (== ' ')) names
        )
        ("promise serialization mismatch: " ++ show names)

promiseFromNameTest :: IO Result
promiseFromNameTest =
    expect
        ( and
            [ promiseFromName (promiseName promise) == Just promise
            | promise <- [minBound .. maxBound :: Promise]
            ]
            && promiseFromName "tmppath" == Nothing
            && promiseFromName "" == Nothing
            && promiseFromName "bogus" == Nothing
#ifdef OPENBSD_80
            && promiseFromName "exec" == Nothing
            && promiseFromName "error" == Nothing
#else
            && promiseFromName "exec" == Just Exec
            && promiseFromName "error" == Just Error
#endif
        )
        "promiseFromName round-trip mismatch"

unveilPermissionsTest :: IO Result
unveilPermissionsTest =
    expect
        ( permissionString [] == ""
            && permissionString [Read, Write, Execute, Create] == "rwxc"
            && permissionString [Create, Read] == "cr"
        )
        "permission serialization mismatch"

-- Input validation tests (no kernel state involved)

nulRejectionTests :: [(String, IO Result)]
nulRejectionTests =
    [
        ( "unveil: rejects embedded NUL bytes in paths"
        , expectIOError "unveil NUL" (unveil "/tmp\0etc" [Read])
        )
    ,
        ( "priv: rejects embedded NUL bytes in account names"
        , expectIOError "accountByName NUL" (accountByName "nobody\0root")
        )
    ,
        ( "priv: rejects embedded NUL bytes in dropPrivileges"
        , expectIOError "dropPrivileges NUL" (dropPrivileges "nobody\0root")
        )
    ,
        ( "priv: rejects embedded NUL bytes in initGroups"
        , expectIOError "initGroups NUL" (initGroups "nobody\0root" 0)
        )
    ,
        ( "chroot: rejects embedded NUL bytes in paths"
        , expectIOError "chroot NUL" (chroot "/tmp\0etc")
        )
    ,
        ( "chroot: enterChroot rejects embedded NUL bytes"
        , expectIOError "enterChroot NUL" (enterChroot "/tmp\0etc")
        )
    ,
        ( "proc: rejects embedded NUL bytes in process titles"
        , expectIOError "setProcessTitle NUL" (setProcessTitle "a\0b")
        )
    ,
        ( "random: rejects negative buffer lengths"
        , expectIOError "arc4RandomBytes negative" (arc4RandomBytes (-1))
        )
    ,
        ( "proc: forkExec rejects embedded NUL bytes"
        , expectIOError "forkExec NUL" (forkExec "/tmp\0x" False [] Nothing)
        )
    ,
        ( "proc: forkExecPledged rejects embedded NUL bytes"
        , expectIOError "forkExecPledged NUL" (forkExecPledged [Stdio] "/tmp\0x" False [] Nothing)
        )
    ,
        ( "proc: execPledged rejects embedded NUL bytes"
        , expectIOError "execPledged NUL" (execPledged [Stdio] "/tmp\0x" False [] Nothing)
        )
    ,
        ( "proc: setProgramName rejects embedded NUL bytes"
        , expectIOError "setProgramName NUL" (setProgramName "a\0b")
        )
    ,
        ( "random: getEntropy rejects lengths above 256"
        , expectIOError "getEntropy long" (getEntropy 257)
        )
    ,
        ( "random: getEntropy rejects negative lengths"
        , expectIOError "getEntropy negative" (getEntropy (-1))
        )
    ,
        ( "auth: cryptCheckpass rejects embedded NUL bytes"
        , expectIOError "cryptCheckpass NUL" (cryptCheckpass (BS.pack [0]) "hash")
        )
    ,
        ( "auth: cryptNewhash rejects embedded NUL bytes"
        , expectIOError "cryptNewhash NUL" (cryptNewhash (BS.pack [0]) "bcrypt,4")
        )
    ,
        ( "auth: bcryptPbkdf rejects negative key lengths"
        , expectIOError "bcryptPbkdf negative" (bcryptPbkdf "p" "s" 4 (-1))
        )
    ,
        ( "memory: immutableMemory rejects negative lengths"
        , expectIOError "immutableMemory negative" (immutableMemory nullPtr (-1))
        )
    ]

-- pledge tests

{- | The @_exit(2)@-only pledge state is valid OpenBSD and is
verified by a standalone C probe (test\/fixtures\/pledge-empty-probe.c)
that performs the complete operation with native @fork(2)@:

> fork -> child: pledge("", NULL) -> _exit(0)
> parent: waitpid, strict exit-vs-signal inspection

plus the direct non-forked @pledge("") -> _exit(0)@ case.  The
probe distinguishes normal exit, SIGABRT and other signals,
pledge failure and waitpid failure with distinct exit statuses.

It is intentionally NOT tested by calling @pledge("")@ from a
'forkProcess' child under the threaded GHC RTS: reducing the
current promise set to the empty state makes the kernel unwind
sibling runtime threads while cleaning up the now-inaccessible
unveil state, and the resumed threads then perform syscalls
forbidden by the empty promise set, so the kernel aborts the
process.  (A call that only configures execpromises does not take
that path.)  This is an interaction between the kernel's thread
handling during extreme current-process reduction and the runtime
environment, not a defect of pledge(2) or of this binding.
-}
pledgeEmptyTest :: IO Result
pledgeEmptyTest = do
    pid <- getProcessID
    let source = "test/fixtures/pledge-empty-probe.c"
        probe = "/tmp/openbsd-pledge-empty-probe-" ++ show pid
    bracket
        ( (compileFixture source probe `onException` ignoreIOException (removeFile probe))
            >> pure probe
        )
        (\path -> ignoreIOException (removeFile path))
        $ \path -> do
            output <- captureOutput path []
            case output of
                Left e -> pure (Fail ("probe failed: " ++ e))
                Right _ -> pure Pass

compileFixture :: FilePath -> FilePath -> IO ()
compileFixture = compileFixtureWith []

{- | The execpledge target must be static: a dynamically linked
executable needs rpath at startup for ld.so, which the stdio exec
ceiling forbids.
-}
compileStaticFixture :: FilePath -> FilePath -> IO ()
compileStaticFixture = compileFixtureWith ["-static"]

{- | Compile the shared execpledge fixture once in the test runner and
remove it even when a child fails, times out, or is replaced by exec.
-}
withExecPledgeProbe :: (FilePath -> IO a) -> IO a
withExecPledgeProbe action = do
    pid <- getProcessID
    let probe = "/tmp/openbsd-execpledge-probe-" ++ show pid
    bracket
        ( ( compileStaticFixture "test/fixtures/execpledge-probe.c" probe
                `onException` ignoreIOException (removeFile probe)
          )
            >> pure probe
        )
        (\path -> ignoreIOException (removeFile path))
        action

compileFixtureWith :: [String] -> FilePath -> FilePath -> IO ()
compileFixtureWith flags source output = do
    result <-
        captureOutput
            "/usr/bin/cc"
            ( ["-std=c23", "-Wall", "-Wextra", "-Werror"]
                ++ flags
                ++ ["-o", output, source]
            )
    case result of
        Left e -> fail ("cc failed for " ++ source ++ ": " ++ e)
        Right _ -> pure ()

{- | Fork a child that immediately execs @prog@ with @args@,
capturing stdout and stderr.  The child performs no pledge call
and no other meaningful Haskell work: its only purpose is to reach
exec as directly as possible.
-}
execCapture :: FilePath -> [String] -> IO (Maybe ProcessStatus, String)
execCapture prog args = do
    (readFd, writeFd) <- createPipe
    child <- forkProcess $ do
        closeFd readFd
        _ <- dupTo writeFd stdOutput
        _ <- dupTo writeFd stdError
        closeFd writeFd
        _ <- executeFile prog True args Nothing
        _ <- exitImmediately (ExitFailure 127)
        pure ()
    closeFd writeFd
    output <- timeout 60000000 $
        bracket (fdToHandle readFd) hClose $ \h -> do
            hSetBinaryMode h True
            captured <- hGetContents h
            _ <- evaluate (length captured)
            pure captured
    status <- waitForProcess child
    pure (status, maybe "" id output)

{- | The supported fork architecture under the threaded RTS:

> parent: pledgeChild [Stdio]  (exec ceiling, parent-side)
> parent: still unrestricted    (an rpath-class open succeeds)
> forkProcess
> child:  executeFile immediately (no pledge call in the child)
> new image starts under the inherited execpromises

OpenBSD copies PS_EXECPLEDGE and ps_execpledge across fork(2) and
applies them when the descendant executes a new image, so the
parent-side setting survives the fork.  Verified through actual
allowed and forbidden operations, not by trusting return values.
-}
forkExecPledgeTest :: IO Result
forkExecPledgeTest = withExecPledgeProbe $ \probe ->
    inChild "fork-exec" $ do
        -- Configure the exec ceiling in the parent, before any fork.
        pledgeChild [Stdio]

        -- Exec promises do not restrict the current process: an
        -- operation outside the child's future promise set still works.
        nullHandle <- openFile "/dev/null" ReadMode
        _ <- evaluate (length <$> hGetContents nullHandle)
        hClose nullHandle

        (allowedStatus, allowedOut) <- execCapture probe []
        when (allowedOut /= "execpledge-ok\n") $
            fail ("unexpected allowed-case output: " ++ show allowedOut)
        case allowedStatus of
            Just (Exited ExitSuccess) -> pure ()
            other -> fail ("allowed case did not exit normally: " ++ show other)

        (forbiddenStatus, _) <- execCapture probe ["violate"]
        case forbiddenStatus of
            Just (Terminated signal _) | signal == sigABRT -> pure ()
            other ->
                fail
                    ( "expected SIGABRT for the forbidden open, got: "
                        ++ show other
                    )

pledgeNullTest :: IO Result
pledgeNullTest = inChild "pledge-null" $ do
    pledge [Stdio]
    pledgeParts Nothing Nothing
    pledge [Stdio]
    pledgeBoth [Stdio] [Stdio]
    pledgeParts (Just [Stdio]) Nothing

{- | pledge(NULL, "") restricts exec promises to the empty set while
leaving the current promises unchanged; the process itself must
remain functional.
-}
pledgeNullExecEmptyTest :: IO Result
pledgeNullExecEmptyTest = inChild "pledge-null-exec-empty" $ do
    pledge [Stdio]
    pledgeParts Nothing (Just [])
    void getProcessID
    pledge [Stdio]

pledgeIncreaseTest :: IO Result
pledgeIncreaseTest = inChild "pledge-increase" $ do
    pledge [Stdio]
    assertErrno ePERM "promise increase" (pledge [Stdio, Rpath])

pledgeExecIncreaseTest :: IO Result
pledgeExecIncreaseTest = inChild "pledge-exec-increase" $ do
    pledgeBoth [Stdio] [Stdio]
    assertErrno ePERM "exec promise increase" (pledgeChild [Stdio, Rpath])

{- | A violation of a normal, non-empty promise set aborts the process
with SIGABRT.  The @_exit(2)@-only state is deliberately not entered
from a threaded @forkProcess@ child; that unsupported transition is
covered by the native probe in 'pledgeEmptyTest' instead.
-}
pledgeViolationTest :: IO Result
pledgeViolationTest = expectSignal sigABRT $ do
    pledge [Stdio]
    _ <- openFile "/etc/hostname" ReadMode
    pure ()

-- unveil tests

unveilLockTest :: IO Result
unveilLockTest = inChild "unveil-lock" $ do
    unveilPaths [("/", [Read, Execute]), ("/tmp", [Read, Write, Create])]
    lockUnveil
    assertErrno ePERM "unveil after locking" (unveil "/etc" [Read])

{- | unveil(2) resolves non-directory paths with namei in CREATE mode:
the final component may legitimately not exist (it is remembered by
name).  Only a nonexistent *directory* component fails with ENOENT.
-}
unveilNonexistentTest :: IO Result
unveilNonexistentTest = inChild "unveil-enoent" $ do
    assertErrno
        eNOENT
        "unveil with a nonexistent directory"
        (unveil "/openbsd-test-dir-that-does-not-exist/file" [Read])

unveilEnforcementTest :: IO Result
unveilEnforcementTest = do
    pid <- getProcessID
    let forbidden = "/tmp/openbsd-test-forbidden-file-" ++ show pid
    result <-
        finally
            ( inChild "unveil-enforcement" $ do
                unveilPaths [("/", [Read, Execute])]
                lockUnveil
                contents <- try (readFile "/dev/null") :: IO (Either IOException String)
                case contents of
                    Left e -> fail ("reading /dev/null should succeed: " ++ displayException e)
                    Right "" -> pure ()
                    Right s -> fail ("unexpected /dev/null contents: " ++ show s)
                written <- try (writeFile forbidden "forbidden")
                case written of
                    Left (_ :: IOException) -> pure ()
                    Right () -> fail "writing /tmp succeeded under unveil / r x"
            )
            -- The child can no longer remove the file after locking
            -- unveil; the runner cleans it up even if the wait fails.
            (ignoreIOException (removeFile forbidden))
    pure result

{- | The empty permission set unveils a path but permits no operation
on it.  Reading the directory itself is a direct test.
-}
unveilEmptyPermissionsTest :: IO Result
unveilEmptyPermissionsTest = inChild "unveil-empty-permissions" $ do
    unveil "/tmp" []
    lockUnveil
    result <- try (getDirectoryContents "/tmp") :: IO (Either IOException [FilePath])
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
    assertErrno
        ePERM
        "regaining root uid"
        (setResUserID (Just rootUid) (Just rootUid) (Just rootUid))
    assertErrno
        ePERM
        "regaining root gid"
        (setResGroupID (Just rootGid) (Just rootGid) (Just rootGid))

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

{- | Dropping to the root account by name is refused instead of
silently succeeding while leaving the process privileged.
-}
dropRootRefusedTest :: IO Result
dropRootRefusedTest = inChild "privdrop-root" $ do
    result <- try (dropPrivileges "root")
    case result of
        Left (_ :: IOException) -> pure ()
        Right () -> fail "dropPrivileges accepted the root account"

{- | Without sufficient privileges the drop must fail early with the
native EPERM preserved through the masked transition, instead of
silently pretending to succeed.
-}
dropUnprivilegedTest :: IO Result
dropUnprivilegedTest = inChild "privdrop-eperm" $ do
    account <- accountByName "nobody"
    let uid = accountUid account
    _ <- try (setResUserID (Just uid) (Just uid) (Just uid)) :: IO (Either IOException ())
    assertErrno
        ePERM
        "dropPrivileges without privileges"
        (dropPrivileges "nobody")

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

{- | The native -1 semantics: Nothing leaves each ID unchanged, and
the no-op call succeeds for any caller.
-}
setResPassthroughTest :: IO Result
setResPassthroughTest = inChild "setres-passthrough" $ do
    beforeUid <- getResUserID
    setResUserID Nothing Nothing Nothing
    afterUid <- getResUserID
    when (beforeUid /= afterUid) (fail "setresuid(-1,-1,-1) changed the IDs")
    beforeGid <- getResGroupID
    setResGroupID Nothing Nothing Nothing
    afterGid <- getResGroupID
    when (beforeGid /= afterGid) (fail "setresgid(-1,-1,-1) changed the IDs")

-- chroot tests

{- | Deterministic in both the privileged and unprivileged phases: the
child makes itself unprivileged first if necessary, then chroot
must fail with EPERM.
-}
chrootEpermTest :: IO Result
chrootEpermTest = inChild "chroot-eperm" $ do
    account <- accountByName "nobody"
    let uid = accountUid account
    _ <- try (setResUserID (Just uid) (Just uid) (Just uid)) :: IO (Either IOException ())
    assertErrno ePERM "chroot without privileges" (chroot "/")

enterChrootTest :: IO Result
enterChrootTest = requireRoot $ do
    pid <- getProcessID
    let rootDir = "/tmp/openbsd-enterchroot-test-" ++ show pid
        marker = rootDir ++ "/marker"
        cleanup = do
            ignoreIOException (removeFile marker)
            ignoreIOException (removeDirectory rootDir)
    (createDirectoryIfMissing True rootDir >> writeFile marker "inside")
        `onException` cleanup
    finally
        ( inChild "enterchroot" $ do
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
        )
        cleanup

-- credential tests

issetugidPlainTest :: IO Result
issetugidPlainTest = inChild "issetugid-false" $ do
    tainted <- isSetugid
    when tainted (fail "untainted process reports issetugid")

{- | A plain exec of a non-set-ID binary must leave the process
untainted.
-}
issetugidPlainExecTest :: IO Result
issetugidPlainExecTest =
    bracket
        issetugidProbeFixture
        (\probe -> ignoreIOException (removeFile probe))
        $ \probe -> do
            output <- captureOutput probe []
            case output of
                Left e -> pure (Fail ("probe failed: " ++ e))
                Right s ->
                    expect
                        (s == "0\n")
                        ("plain exec reported taint, got: " ++ show s)

{- | The kernel sets PS_SUGIDEXEC either when the executed file
carries set-ID bits or when the exec happens with mismatched real
and effective IDs.  This test uses the mismatched-ID path: it does
not depend on the filesystem honoring set-ID bits, which varies by
environment, and exercises the same taint mechanism.
-}
issetugidSuidExecTest :: IO Result
issetugidSuidExecTest = requireRoot $
    bracket
        issetugidProbeFixture
        (\probe -> ignoreIOException (removeFile probe))
        $ \probe -> do
            nobody <- accountByName "nobody"
            let uid = accountUid nobody
            (readFd, writeFd) <- createPipe
            child <- forkProcess $ do
                closeFd readFd
                _ <- dupTo writeFd stdOutput
                closeFd writeFd
                setResUserID (Just 0) (Just uid) Nothing
                _ <- executeFile probe True [] Nothing
                _ <- exitImmediately (ExitFailure 127)
                pure ()
            closeFd writeFd
            output <- timeout 60000000 $
                bracket (fdToHandle readFd) hClose $ \h -> do
                    hSetBinaryMode h True
                    captured <- hGetContents h
                    _ <- evaluate (length captured)
                    pure captured
            status <- waitForProcess child
            case (output, status) of
                (Just "1\n", Just (Exited ExitSuccess)) -> pure Pass
                (Just "1\n", other) ->
                    pure (Fail ("set-ID probe exited unexpectedly: " ++ show other))
                (Just other, _) ->
                    pure (Fail ("set-ID exec not detected, got: " ++ show other))
                (Nothing, _) -> pure (Fail "probe timed out")

getpeereidTest :: IO Result
getpeereidTest = inChild "getpeereid" $ do
    (a, b) <- socketPair
    (uid, gid) <- getPeerCredentials a
    euid <- getEffectiveUserID
    egid <- getEffectiveGroupID
    closeFd a
    closeFd b
    when (uid /= euid || gid /= egid) $
        fail
            ( "peer credentials mismatch: "
                ++ show (uid, gid)
                ++ " vs "
                ++ show (euid, egid)
            )

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
                    status <- waitForProcess child
                    hClose outHandle
                    hClose controlHandle
                    pure $ case status of
                        Just (Exited ExitSuccess) -> case withTitle of
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
                        other -> Fail ("child exited unexpectedly: " ++ show other)
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

{- | The arc4random family must work under pledge stdio: it only
requires getentropy(2), which is part of the stdio promise.
-}
arc4randomPledgeTest :: IO Result
arc4randomPledgeTest = inChild "arc4random-pledge" $ do
    pledge [Stdio]
    _ <- arc4Random
    buf <- arc4RandomBytes 64
    when (BS.length buf /= 64) (fail "wrong buffer length under pledge")
    _ <- arc4RandomUniform 10
    pure ()

-- exec-helper tests

{- | The public forkExec: fork plus immediate exec, no pledge policy
involved; the target runs normally.
-}
forkExecTest :: IO Result
forkExecTest = withExecPledgeProbe $ \probe ->
    inChild "fork-exec-plain" $ do
        pid <- forkExec probe False [] Nothing
        status <- waitForProcess pid
        case status of
            Just (Exited ExitSuccess) -> pure ()
            other -> fail ("executed target did not exit normally: " ++ show other)

{- | The public forkExecPledged: exec promises configured in the
caller, inherited across fork, and applied to the new image; the
allowed case exits 0 and the forbidden case dies of SIGABRT.
-}
forkExecPledgedTest :: IO Result
forkExecPledgedTest = withExecPledgeProbe $ \probe ->
    inChild "fork-exec-pledged" $ do
        allowedPid <- forkExecPledged [Stdio] probe False [] Nothing
        allowedStatus <- waitForProcess allowedPid
        case allowedStatus of
            Just (Exited ExitSuccess) -> pure ()
            other -> fail ("allowed case did not exit normally: " ++ show other)

        forbiddenPid <- forkExecPledged [Stdio] probe False ["violate"] Nothing
        forbiddenStatus <- waitForProcess forbiddenPid
        case forbiddenStatus of
            Just (Terminated signal _) | signal == sigABRT -> pure ()
            other ->
                fail
                    ( "expected SIGABRT for the forbidden open, got: "
                        ++ show other
                    )

{- | The public execPledged: replace the current image under the given
exec promise ceiling.
-}
execPledgedAllowedTest :: IO Result
execPledgedAllowedTest = withExecPledgeProbe $ \probe ->
    inChild "exec-pledged-ok" $ do
        execPledged [Stdio] probe True [] Nothing

execPledgedViolationTest :: IO Result
execPledgedViolationTest = withExecPledgeProbe $ \probe ->
    expectSignal sigABRT $ do
        execPledged [Stdio] probe True ["violate"] Nothing

-- descriptor tests

{- | closefrom(2) through a raw fork child: descriptor checks use
dup(2) only, since Handle-based I/O is unusable after closefrom.
-}
closeFromTest :: IO Result
closeFromTest = do
    child <- forkProcess $ do
        fds <- forM [1 .. 3 :: Int] $ \_ -> do
            h <- openFile "/dev/null" ReadMode
            handleToFd h
        case fds of
            [low, mid, high] -> do
                closeFrom mid
                okLow <- checkFdOpen low
                okMid <- checkFdOpen mid
                okHigh <- checkFdOpen high
                okStd <- and <$> mapM checkFdOpen [stdInput, stdOutput, stdError]
                closeFd low
                c__exit
                    ( if okLow && not okMid && not okHigh && okStd
                        then 0
                        else
                            if not okLow
                                then 11
                                else
                                    if okMid
                                        then 12
                                        else
                                            if okHigh
                                                then 13
                                                else 14
                    )
            _ -> c__exit 15
    status <- waitForProcess child
    case status of
        Just (Exited ExitSuccess) -> pure Pass
        Just (Exited (ExitFailure code)) -> pure (Fail ("closefrom check " ++ show code))
        other -> pure (Fail ("child: " ++ show other))

{- | closefrom(2) reports @EBADF@ when the argument is greater than
every open descriptor.  The wrapper must surface that errno rather
than silently ignoring the native result.
-}
closeFromEbadfTest :: IO Result
closeFromEbadfTest = inChild "closefrom-ebadf" $ do
    result <- try (closeFrom (Fd 1_000_000)) :: IO (Either IOException ())
    case result of
        Left e -> case IOE.ioe_errno e of
            Just c | Errno c == eBADF -> pure ()
            other ->
                fail
                    ( "expected EBADF from closeFrom, got "
                        ++ displayException e
                        ++ " (errno "
                        ++ show other
                        ++ ")"
                    )
        Right () -> fail "closeFrom beyond the table was accepted"

getDescriptorCountTest :: IO Result
getDescriptorCountTest = inChild "dtablecount" $ do
    count0 <- getDescriptorCount
    handles <- forM [1 .. 5 :: Int] (\_ -> openFile "/dev/null" ReadMode)
    count1 <- getDescriptorCount
    mapM_ hClose handles
    when (count1 <= count0) (fail "descriptor count did not increase")
    pledge [Stdio]
    count2 <- getDescriptorCount
    when (count2 <= 0) (fail "bogus descriptor count under pledge")

-- program-name tests

prognameTest :: IO Result
prognameTest = inChild "progname" $ do
    setProgramName "obd-progname-test"
    name <- getProgramName
    when (name /= "obd-progname-test") $
        fail ("program name mismatch: " ++ show name)

#ifdef OPENBSD_80
-- getexecpath tests

getExecPathTest :: IO Result
getExecPathTest = inChild "getexecpath" $ do
    path <- getExecPath
    when (null path) (fail "empty executable path")
    unless (take 1 path == "/") (fail ("not an absolute path: " ++ show path))
#endif

-- entropy tests

getEntropyTest :: IO Result
getEntropyTest = inChild "getentropy" $ do
    b0 <- getEntropy 0
    when (BS.length b0 /= 0) (fail "zero-length entropy request")
    b1 <- getEntropy 1
    when (BS.length b1 /= 1) (fail "one-byte entropy request")
    b256 <- getEntropy 256
    when (BS.length b256 /= 256) (fail "256-byte entropy request")
    pledge [Stdio]
    b16 <- getEntropy 16
    when (BS.length b16 /= 16) (fail "entropy request under pledge")

-- routing-domain tests

rtableGetTest :: IO Result
rtableGetTest = inChild "rtable-get" $ do
    table <- getRtable
    when (unRtable table < 0) (fail "negative rtable id")

{- | In the default environment only domain 0 exists: setting it is
a no-op, and any other domain fails with EINVAL (the kernel checks
rtable_exists).  A configured domain 1 is also legitimate, however,
so a successful switch is accepted and the forked child exits with
that domain.  The EPERM rule for changing a configured non-zero
domain requires root and a configured domain; it is documented and
enforced by the kernel but not exercised here.
-}
rtableTest :: IO Result
rtableTest = inChild "rtable" $ do
    current <- getRtable
    when (unRtable current < 0) (fail "negative rtable id")
    setRtable current
    again <- getRtable
    when (again /= current) (fail "rtable changed on a no-op set")
    result <- try (setRtable (Rtable 1))
    case result of
        Left e -> case IOE.ioe_errno e of
            Just c | Errno c == eINVAL || Errno c == ePERM -> pure ()
            other ->
                fail
                    ( "unexpected errno for an unconfigured or forbidden domain: "
                        ++ show other
                    )
        -- Domain 1 is configured and the caller was allowed to switch.
        Right () -> pure ()

{- | A domain value that does not fit in the native @int@ is rejected
instead of being silently truncated to a different domain.
-}
rtableOutOfRangeTest :: IO Result
rtableOutOfRangeTest = inChild "rtable-range" $ do
    result <- try (setRtable (Rtable (maxBound :: Int)))
    case result of
        Left (_ :: IOException) -> pure ()
        Right () -> fail "setRtable accepted an out-of-range domain"

-- memory tests

timingSafeEqualTest :: IO Result
timingSafeEqualTest = inChild "timingsafe-eq" $ do
    t1 <- timingSafeEqual "abc" "abc"
    t2 <- timingSafeEqual "abc" "abd"
    t3 <- timingSafeEqual "x" "x"
    t4 <- timingSafeEqual "" ""
    t5 <- timingSafeEqual "a" ""
    t6 <- timingSafeEqual (BS.pack [1, 2, 3]) (BS.pack [1, 2, 3])
    t7 <- timingSafeEqual (BS.pack [1, 2, 3]) (BS.pack [1, 2, 4])
    when (not (and [t1, t3, t4, t6] && not (or [t2, t5, t7]))) $
        fail "timingSafeEqual mismatch"

timingSafeCompareTest :: IO Result
timingSafeCompareTest = inChild "timingsafe-cmp" $ do
    r1 <- timingSafeCompare "abc" "abd"
    r2 <- timingSafeCompare "abd" "abc"
    r3 <- timingSafeCompare "abc" "abc"
    r4 <- timingSafeCompare "ab" "abc"
    r5 <- timingSafeCompare "abc" "ab"
    r6 <- timingSafeCompare "" ""
    when ([r1, r2, r3, r4, r5, r6] /= [LT, GT, EQ, LT, GT, EQ]) $
        fail "timingSafeCompare mismatch"

immutableMemoryReadTest :: IO Result
immutableMemoryReadTest = inChild "mimmutable-read" $ do
    page <-
        c_mmap
            nullPtr
            4096
            protReadWrite
            (mapAnon .|. mapPrivate)
            (-1)
            0
    when (page == intPtrToPtr (-1)) (fail "mmap failed")
    pokeByteOff page 0 (0x7a :: Word8)
    before <- peek (castPtr page :: Ptr Word8)
    immutableMemory page 4096
    after <- peek (castPtr page :: Ptr Word8)
    when (before /= after) (fail "content changed after mimmutable")

{- | mimmutable blocks future protection changes on a page mapped by
the test itself: mprotect to a different protection fails, while
reads and writes remain allowed.
-}
immutableMemoryProtectionTest :: IO Result
immutableMemoryProtectionTest = inChild "mimmutable-protect" $ do
    page <-
        c_mmap
            nullPtr
            4096
            protReadWrite
            (mapAnon .|. mapPrivate)
            (-1)
            0
    when (page == intPtrToPtr (-1)) (fail "mmap failed")
    pokeByteOff page 0 (0x7a :: Word8)
    before <- peek (castPtr page :: Ptr Word8)
    immutableResult <- c_mimmutable page 4096
    when (immutableResult /= 0) (fail "mimmutable failed")
    pokeByteOff page 0 (0x42 :: Word8)
    written <- peek (castPtr page :: Ptr Word8)
    when (written /= 0x42) (fail "write after mimmutable did not stick")
    protected <- c_mprotect page 4096 protRead
    when
        (protected == 0)
        ( fail
            ( "mprotect succeeded on immutable memory "
                ++ "(before: "
                ++ show before
                ++ ")"
            )
        )
    _ <- c_munmap page 4096
    pure ()

explicitBzeroTest :: IO Result
explicitBzeroTest = inChild "explicit-bzero" $ do
    buffer <- mallocBytes 64
    mapM_ (\i -> pokeByteOff buffer i (0x5a :: Word8)) [0 .. 63]
    explicitBzero buffer 64
    contents <- peekArray 64 (buffer :: Ptr Word8)
    when (any (/= 0) contents) (fail "buffer not zeroed")
    free buffer

{- | Smoke test for @freezero(3)@.  Reading the buffer after it has
been freed would be a use-after-free, so the observable contract is
that the call completes without crashing; the erasure itself is
covered by the native function and by 'explicitBzeroTest'.
-}
freeZeroTest :: IO Result
freeZeroTest = inChild "freezero" $ do
    buffer <- mallocBytes 32
    freeZero buffer 32

-- authentication tests

cryptCheckpassTest :: IO Result
cryptCheckpassTest = inChild "crypt" $ do
    hash <- cryptNewhash "correct horse battery staple" "bcrypt,4"
    matching <- cryptCheckpass "correct horse battery staple" hash
    when (not matching) (fail "matching password rejected")
    wrong <- cryptCheckpass "wrong password" hash
    when wrong (fail "wrong password accepted")

cryptNewhashInvalidPrefTest :: IO Result
cryptNewhashInvalidPrefTest = inChild "crypt-badpref" $ do
    assertErrno
        eINVAL
        "cryptNewhash with an unsupported preference"
        (cryptNewhash "pw" "bogus,9")

bcryptPbkdfTest :: IO Result
bcryptPbkdfTest = inChild "bcrypt-pbkdf" $ do
    key <- bcryptPbkdf "password" "salt" 4 32
    when (BS.length key /= 32) (fail "wrong key length")
    key2 <- bcryptPbkdf "password" "salt" 4 32
    when (key /= key2) (fail "derivation not deterministic")
    emptyKey <- bcryptPbkdf "password" "salt" 4 0
    when (BS.length emptyKey /= 0) (fail "zero-length key not empty")

-- daemonization tests

sessionCheck :: IO Bool
sessionCheck = (==) <$> getProcessGroupID <*> getProcessID

cwdCheck :: FilePath -> IO Bool
cwdCheck expected = (== expected) <$> getCurrentDirectory

{- | Standard descriptors are considered open when dup(2) succeeds
on each of them.  This probes the raw descriptors directly,
without involving the RTS IO manager (whose state after nested
forks is not the point of this test).
-}
stdFdsOpenCheck :: IO [Bool]
stdFdsOpenCheck = mapM checkFdOpen [stdInput, stdOutput, stdError]

checkFdOpen :: Fd -> IO Bool
checkFdOpen fd = do
    result <- try (dup fd) :: IO (Either IOException Fd)
    case result of
        Left _ -> pure False
        Right duped -> closeFd duped >> pure True

{- | The daemonized child reports via an inherited pipe; the original
process exits inside 'daemonize', exactly like daemon(3).
-}
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
    output <- timeout 60000000 $
        bracket (fdToHandle readFd) hClose $ \h -> do
            s <- hGetContents h
            _ <- evaluate (length s)
            pure s
    status <- waitForProcess helper
    case (output, status) of
        (Nothing, _) -> pure (Fail "timed out waiting for the daemonized child")
        (_, Just (Exited ExitSuccess)) ->
            expect
                (output == Just "checks [True,True,True,True,True]\n")
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
        daemonizeWith
            defaultDaemonOptions
                { changeDirectoryToRoot = False
                , redirectStandardStreams = False
                }
            $ do
                ok1 <- sessionCheck
                ok2 <- cwdCheck originalCwd
                fds <- stdFdsOpenCheck
                hPutStrLn report ("checks " ++ show ([ok1, ok2] ++ fds))
                hFlush report
    closeFd writeFd
    output <- timeout 60000000 $
        bracket (fdToHandle readFd) hClose $ \h -> do
            s <- hGetContents h
            _ <- evaluate (length s)
            pure s
    status <- waitForProcess helper
    case (output, status) of
        (Nothing, _) -> pure (Fail "timed out waiting for the daemonized child")
        (_, Just (Exited ExitSuccess)) ->
            expect
                (output == Just "checks [True,True,True,True,True]\n")
                ("unexpected daemon report: " ++ show output)
        _ -> pure (Fail ("daemonize helper failed: " ++ show status))

pureTests :: [(String, IO Result)]
pureTests =
    [ ("pledge: serializes every promise", promiseNamesTest)
    , ("pledge: promiseFromName round-trips", promiseFromNameTest)
    , ("unveil: serializes permission sets", unveilPermissionsTest)
    ]
        ++ nulRejectionTests

runtimeTests :: [(String, IO Result)]
runtimeTests =
    [ ("pledge: empty promise list restricts to _exit", pledgeEmptyTest)
    , ("pledge: fork plus immediate exec applies execpromises", forkExecPledgeTest)
    , ("proc: forkExec runs the target", forkExecTest)
    , ("proc: forkExecPledged applies the exec ceiling", forkExecPledgedTest)
    , ("proc: execPledged starts the new image pledged", execPledgedAllowedTest)
    , ("proc: execPledged violation dies of SIGABRT", execPledgedViolationTest)
    , ("proc: closeFrom closes descriptors", closeFromTest)
    , ("proc: closeFrom surfaces EBADF beyond the table", closeFromEbadfTest)
    , ("proc: getDescriptorCount reflects open descriptors", getDescriptorCountTest)
    , ("proc: setProgramName/getProgramName round-trip", prognameTest)
    , ("random: getEntropy returns requested lengths", getEntropyTest)
    , ("rtable: getRtable works unprivileged", rtableGetTest)
    , ("rtable: setRtable enforces existing domains", rtableTest)
    , ("rtable: setRtable rejects out-of-range domains", rtableOutOfRangeTest)
    , ("memory: timingSafeEqual semantics", timingSafeEqualTest)
    , ("memory: timingSafeCompare semantics", timingSafeCompareTest)
    , ("memory: mimmutable keeps reads working", immutableMemoryReadTest)
    , ("memory: mimmutable blocks protection changes", immutableMemoryProtectionTest)
    , ("memory: explicitBzero zeroes the buffer", explicitBzeroTest)
    , ("memory: freeZero releases the buffer", freeZeroTest)
    , ("auth: cryptNewhash/cryptCheckpass round-trip", cryptCheckpassTest)
    , ("auth: cryptNewhash rejects unsupported preferences", cryptNewhashInvalidPrefTest)
    , ("auth: bcryptPbkdf derives deterministic keys", bcryptPbkdfTest)
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
    , ("priv: dropPrivileges refuses the root account", dropRootRefusedTest)
    , ("priv: dropPrivileges fails with EPERM without privileges", dropUnprivilegedTest)
    , ("priv: setResUserID/setResGroupID honor the -1 passthrough", setResPassthroughTest)
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
#ifdef OPENBSD_80
        ++ [("proc: getExecPath returns an absolute path", getExecPathTest)]
#endif

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
