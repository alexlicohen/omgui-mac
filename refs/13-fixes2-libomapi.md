# libomapi fix pass 2 — shutdown and removal (H1–H4, M1, L1, U3)

Answers `refs/12-deep-review-2.md`. The first pass (`refs/11-fixes-libomapi.md`, C3/C6/C17) moved
the quit-path use-after-free rather than closing it, so this is one redesign of the download/
discovery lifecycle, not seven patches. Row-by-row rationale is in `Vendor/PATCHES.md`
(`omapi-download.c` row 1 tells the whole design once); this file records the shape, what is
deliberately *not* fixed, and what only hardware can test.

## The contract

> A download thread publishes `downloadFinished` when it has stopped touching its `OmDeviceState`.
> Nothing frees that state, and nothing destroys a mutex the thread can still take, until it has.

Everything else is a consequence:

| Who | Does | Because |
|---|---|---|
| IOKit removal callback | stores `OM_DEVICE_REMOVED` (atomic), then `OmDownloadRequestCancel()`. **No join.** | It runs on the discovery run-loop thread. A join there stops attach/detach delivery *and* `CFRunLoopStop()` processing, so a quit could not stop discovery at all (H1/H2). |
| `OmShutdown()` | cancels every device, then `OmDownloadJoinBounded()` per device; frees a state only when that returns non-zero; skips both `mutex_destroy()` calls if anything leaked | The one authoritative join, and it must not be able to hang `@MainActor` (H1/H3). |
| `OmDeviceDiscoveryStop()` detach path | nulls the device/download/chunk/log callbacks, clears `gRunLoop`, sets `gDiscoveryDetached`, keeps the notify port and the `DeviceData` registry | The orphan can still walk the device table and call back into a Swift object the caller is about to release (H4). |
| `OmBeginDownloadingReference()` | reaps a finished-but-unjoined thread before starting a new one; refuses if the old one is still running | Otherwise `thread_create` overwrites — and permanently leaks — a joinable handle on every unplug/replug (H1). |

Two supporting decisions worth keeping in mind:

- **The bound is on the flag, not the join.** Darwin has no `pthread_timedjoin_np()`. Once
  `downloadFinished` is up the thread has closed both streams and delivered its final status, so the
  join that follows returns immediately.
- **`dup2("/dev/null")` over the source descriptor, not `fclose()`/`close()`.** It bounds every
  *subsequent* read without tearing down stdio state another thread owns, and without freeing a
  descriptor number that could be reused. It cannot interrupt the read already in flight — which is
  precisely why the join still needs a timeout. Both happen under `om.downloadMutex`, which the
  thread's epilogue also takes around closing and clearing the streams; that pairing is what makes
  reading `downloadSource` from another thread safe at all.

## Deliberate non-goals

- **M1** is fixed by the review's own fallback, not its first suggestion: `gStartMutex`/`gStartCond`
  are statically initialised and never re-initialised, and `OmDeviceDiscoveryStart()` refuses to
  start once `gDiscoveryDetached` is set. A per-run heap context would also work, but a wedged quit
  does not need a second discovery cycle — it needs to not deadlock.
- **U3** stores `OM_DEVICE_REMOVED` (plus a `seq_cst` fence) before rewriting the string fields
  rather than publishing a fresh `OmDeviceState`. Swapping `record->state` leaves the old state
  unfreeable forever — a download thread and any caller holding the pointer may still be using it.
  The residual window is a re-enumerating device reading as not-connected for a few microseconds.
- Leaks on the wedged paths are intentional and logged at level 0: a leaked `OmDeviceState` and two
  leaked mutexes on a quit that was already going wrong, and the notify port plus every registered
  `DeviceData` for an orphaned discovery thread that is still using them.

## Test coverage added

`Tests/OmApiTests/LibOmapiDownloadProtocolTests.swift`, over
`Vendor/libomapi/src/omapi-testhook.c` (`OmTest*`, bound with `@_silgen_name` — `libomapi/include`
holds only the public `omapi.h`, which is deliberately not extended for a test). The hooks stand a
real `OmDeviceState` up over a caller-supplied descriptor and run the real `OmDownloadThread()`
over it; the tests call `OmDownloadRequestCancel()` and `OmDownloadJoinBounded()`, the same
functions the removal callback and `OmShutdown()` call.

The download thread is stopped and released at known points **from inside its own chunk callback**,
which is the only way a test can park it deterministically. An earlier attempt used a pipe with no
writer to stall the copy loop's `fread()`; it raced — the thread saw `downloadCancel` at the top of
the loop and finished in 9 ms without ever reading. The chunk callback has no such window.

| Test | Pins |
|---|---|
| `testRequestCancelDoesNotJoinAndTheBoundedJoinGivesUpRatherThanBlocking` | `OmDownloadRequestCancel()` returns while the thread is parked; the bounded join waits its budget, returns 0, and **keeps** returning 0 after the detach; once released, the thread publishes `downloadFinished`, both streams are clear and the status is `CANCELLED` |
| `testACompletedDownloadClosesBothStreamsAndPublishesFinished` | the epilogue's ordering: by the time `downloadFinished` is visible, the streams are closed, the destination is flushed and the status is `COMPLETE` |
| `testCancellingMidCopyEndsTheDownloadCancelledAndReleasesTheState` | the copy loop observes `downloadCancel` and ends `CANCELLED` |
| `testASecondDownloadReapsTheFirstThreadRatherThanOverwritingItsHandle` | a finished-but-unjoined thread stays `downloadThreadActive` until reaped, and reaping twice is a no-op |
| `LibOmapiDiscoveryLifecycleTests.testRepeatedStartupAndShutdownCyclesComplete` | two real `OmStartup()`/`OmShutdown()` cycles complete (M1's re-init, C17's bounded stop, L1's release order). Starts real IOKit matching, but needs no device attached and passes either way |

## What only hardware can test

None of the following can be reached without an AX3/AX6, and the C-layer tests above do **not**
substitute for them. Run each with `OMDEBUG=2` and keep the log.

1. **Unplug mid-download, then Cmd-Q.** The H1/H2/H3 path end to end. Expect: the removal callback
   returns at once and the device leaves the list immediately (not after the download would have
   finished); the download ends `CANCELLED`; the app quits without a beachball and without a
   crash report. `OmShutdown() done.` must appear. If `WARNING: Download thread for device … did
   not stop` appears, the leak path was taken — still correct, but it means the read did not come
   back inside 2 s and is worth investigating.
2. **Unplug and re-plug quickly, without an intervening download.** The U3 path: `DeviceAdded` for
   a device the table still holds. Expect no torn `root` — the device row must never show a mixed
   or truncated path — and no spurious removal in the UI beyond the one re-connect.
3. **Unplug during a download, then re-plug and download again.** The H1 reap: the second
   `OmBeginDownloading()` must succeed rather than return `OM_E_NOT_VALID_STATE`, and Activity
   Monitor's thread count for the app must not grow by one per cycle.
4. **Quit while a device is mid-enumeration** (attach a unit and hit Cmd-Q inside `findMount()`'s
   ~8 s window). This is the H4 detach path. Expect `WARNING: Device discovery thread did not stop;
   detaching it.` followed by `OmShutdown()` returning without a crash, and no callback into the
   app after that line.
5. **Attach/detach 20 times with the app open**, then check `leaks`/`heap` for `DeviceData` growth
   (L1) and for `OmDeviceState` growth (H1).
