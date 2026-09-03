# Local modifications to vendored sources

Every edit is marked in the source with `PATCH (omgui-mac)`. Baseline commits are in each
directory's `UPSTREAM.md`. Nothing outside this list was changed.

Verification: each file compiles with `clang -c -arch arm64 -Wall -I Vendor/libomapi/include`
with **zero warnings and zero errors** on Xcode 26.6 / macOS 26.6 (arm64).

Rows tagged **C\<n\>** implement the correspondingly numbered confirmed finding in
`refs/10-deep-review.md`.

## `libomapi/include/omapi.h`

| # | What | Why |
|---|---|---|
| 1 | `typedef unsigned long OM_DATETIME;` → `typedef uint32_t OM_DATETIME;` (plus `#include <stdint.h>`) | **Correctness bug on any LP64 build.** `unsigned long` is 32-bit on Windows, where this library was written and where the C# binding declares the same values as `uint`, but 64-bit on macOS. `OM_DATETIME` is a member of the tightly-packed `OM_READER_HEADER_PACKET` / `OM_READER_DATA_PACKET`, whose own comments document it as 4 bytes. Measured on macOS 26 / arm64 before the change: `sizeof(OM_READER_DATA_PACKET)` was **516** (not 512) and every field after `timestamp` was shifted by +4 — `light@22` (should be 18), `temperature@24` (20), `events@26` (22), `battery@27` (23), `sampleRate@28` (24), `numAxesBPS@29` (25), `timestampOffset@30` (26), `sampleCount@32` (28), `rawSampleData@34` (30), `checksum@514` (510, i.e. past the end of the 512-byte buffer). `OM_READER_HEADER_PACKET` was 1032 with `annotation@72` instead of 1024/`@64`. Consequence: `OmReaderGetValue()` returned garbage for `OM_VALUE_LIGHT`, `_TEMPERATURE`, `_EVENTS`, `_BATTERY`, `_SAMPLERATE` and all the cooked `_MC` / `_MV` / `_PERCENT` variants — exactly the values `omapinet`'s `OmReader.ReadBlock()` exposes and OMGUI's DataViewer plots. After the change all offsets match `Docs/ax3/cwa.h` exactly. `OM_DATETIME_INFINITE` becomes `0xFFFFFFFF`, which is still `> OM_DATETIME_MAX_VALID` (`0xFF3F7EFB`), so the `HIBERNATE`/`STOP` sentinel handling in `omapi-settings.c` is unchanged. Guarded by `Tests/OmApiTests/COmApiLayoutTests.swift`. |

## `libomapi/src/omapi-devicefinder-mac.c`

| # | What | Why |
|---|---|---|
| 1 | `kIOMasterPortDefault` → `kIOMainPortDefault` (2 sites: `findSerial`, `IONotificationPortCreate`) | Deprecated in macOS 12; the only deprecation warning the file produced. |
| 2 | `findMount()` rewritten | Upstream recovered the volume *name* by string-scanning `CFCopyDescription()` output (including a stray `if (isdigit(*p)) *p = 'x';` that corrupts any name starting with a digit), assumed the mount point was `/Volumes/<name>`, and assumed the data partition was always `<disk>s1`. A volume name is not a mount point (the mounter appends ` 1` on collision, and names may contain `/`); some units present a "superfloppy" with no partition table, so the volume is the whole disk; and the AX6 does not use the `AX317_` label the file's header comment assumed. The replacement asks DiskArbitration for the real mount path (`kDADiskDescriptionVolumePathKey` → `CFURLGetFileSystemRepresentation`), tries the whole disk plus partitions 1–4, and **selects the volume by the presence of `CWA-DATA.CWA`** — label-independent, so AX3 and AX6 are handled identically. A mounted volume without the data file is accepted only after ~3 s of polling, with a warning (covers the window just after a `FORMAT`). It also releases the `CFStringRef`/`DADiskRef`/`CFDictionaryRef` upstream leaked on every call, and polls `om.quitDiscoveryThread` so shutdown is not blocked. Total wait dropped from up to 22 s to ~8 s. |
| 3 | Added `volumeHasDataFile()` and `mountPathForBsdName()` helpers; added `<ctype.h>` and `<sys/stat.h>` | Support for #2. `isdigit()` was already used in the file with no `<ctype.h>` include. |
| 4 | Removed `cfTypeToCString()` and `cfStringRefToCString()` | Only callers were in the replaced `findMount()`. |
| 5 | Removed `osVersion()`; `serviceMatcher` fixed to `"IOUSBHostDevice"` | `osVersion()` mapped Darwin→macOS as `major - 9`, which was right up to macOS 15 (Darwin 24) and is wrong from macOS 26 (Darwin 25). It only gated an El-Capitan-era `IOUSBDevice`/`IOUSBHostDevice` choice; this build targets macOS 14+, where the class is always `IOUSBHostDevice`. (The stale value happened not to change the outcome, but it is a live landmine.) |
| 6 | Removed the `SIGINT` handler that called `exit(0)` | A library must not take over the host app's Ctrl-C, and must never exit the process on its behalf. Fatal for a GUI app. |
| 7 | `OmDeviceDiscoveryStop()`: `CFRunLoopStop` + `thread_join` instead of `CFRunLoopStop` + `pthread_cancel`; `gRunLoop` NULL-guarded and cleared | `pthread_cancel` immediately after `CFRunLoopStop` can tear the thread down inside CoreFoundation. Joining is now safe because the rewritten `findMount()` observes `om.quitDiscoveryThread`. |
| 8 | `DeviceIdFromSerialNumber()` returns `0` (was `(unsigned int)-1`) when the serial has no digits; caller's test `<= 0` → `== 0` | On an `unsigned int` the caller's `<= 0` could only ever be true for `0`, so the "no device id" path was dead. |
| 9 | Dropped an unused `kern_return_t kr` in `DeviceNotification()` | Silences `-Wunused-but-set-variable`; the two `IOObjectRelease`/`Release` results were never checked. |

| 10 | **C14** `getUSBStringDescriptor()`: reject `wLenDone < 2`, clamp the character count to what `buffer`/the allocation hold, check the `malloc` | `count = (request.wLenDone - 1) / 2` is unsigned arithmetic: a device that ACKs the control transfer with a zero-length string descriptor (a re-enumerating AX3 straight after a `FORMAT`) wrapped it to `0x7FFFFFFF`, and the copy loop then wrote 2.1 GB into a 128-byte heap buffer. |
| 11 | **C6** `DeviceAdded()`: `IOServiceAddInterestNotification()` moved to after every lookup has succeeded, and the failure path given an explicit epilogue (release notification / `deviceName` / device interface, free `serialNumber`, `mountPath`, `serialDevice`) | Upstream armed the `kIOGeneralInterest` notification with `deviceData` as its refCon *before* four steps that can `break` (`getUSBSerialNumber`, `DeviceIdFromSerialNumber`, `findMount`, `findSerial`), then `free()`d the struct bare — leaving a live notification on a dangling pointer. On the eventual unplug `DeviceNotification()` read freed memory and passed garbage `%s` pointers into `OmDeviceDiscovery(OM_DEVICE_REMOVED, ...)`. `findMount()` gives up after ~8 s, so this was reachable just by attaching a unit still re-mounting after a `FORMAT`, or one waiting on "Allow accessory to connect". |
| 12 | **C36** `DeviceNotification()`: free `serialNumber`, `mountPath` and `serialDevice` | ~1.2 KB leaked per attach/detach cycle, unbounded, on the app's hot path. (The first two were previously recorded here as known findings; `mountPath` was introduced by row 2.) |
| 13 | **C17** `OmDeviceDiscoveryStart()`/`Stop()`: `gStarted` is now signalled from a `CFRunLoopPerformBlock` running *inside* the loop (the 200 ms "HACK" delay is gone), the thread also signals on every exit path, `Stop()` retries `CFRunLoopStop()` for up to ~5 s against a `gFinished` condition variable before joining (and detaches rather than hanging if the loop never answers), and the notify port and `gAddedIter` are released | The old signal fired *before* `CFRunLoopRun()`, so a quick quit — which `--self-test` performs by construction — could issue its `CFRunLoopStop()` into a loop that had not started and then block forever in an unbounded `thread_join` on Cmd-Q. Not releasing `gNotifyPort`/`gAddedIter` leaked a mach port per stop/start cycle and left a second matching notification armed. |

Upstream findings now fixed by rows 10–12 (previously recorded here as known leaks, see
`refs/04-phase1-notes.md`): the unfreed `getUSBStringDescriptor()`/`findSerial()` strings, and the
`deviceName` leak on the mid-enumeration failure path.

## `libomapi/src/omapi-internal.h`

| # | What | Why |
|---|---|---|
| 1 | **C15** `OmDeviceState.deviceStatus`, `OmDeviceRecord.state` and `OmState.deviceRecords` are `_Atomic` (`#include <stdatomic.h>`) | The device table is published by the discovery thread and walked, unlocked, by the caller's thread — in OmGui a 100 ms tick on the main thread. The plain store of the list head had no release barrier, so on arm64 a reader could see the new head before the record's own fields, i.e. a record whose `state`/`next` is still pre-`memset` garbage. Qualifying the three fields that cross the boundary makes every existing access a (sequentially consistent) atomic one *without changing a single access site*; records are never removed from the list, and `deviceStatus` is the last field written on connect, so a reader that sees `OM_DEVICE_CONNECTED` also sees the `port`/`root`/`serialId` written before it. |
| 2 | **C3** Declares `OmDownloadCancelJoin(OmDeviceState *)` | See `omapi-download.c` row 1. |

## `libomapi/src/omapi-internal.c`

| # | What | Why |
|---|---|---|
| 1 | `OmPortOpen()` (non-Windows): `if (infile == NULL && infile[0] == '\0')` → `\|\|` | The `&&` form dereferences `infile` after establishing it is `NULL`. Unreachable today (callers pass a `char[]` field), but it is a NULL dereference as written. |
| 2 | **C3** `OmDeviceDiscovery(OM_DEVICE_REMOVED)`: `OmDownloadCancelJoin()` before the status store, replacing the `OmCancelDownload()` call after it | Upstream set `deviceStatus = OM_DEVICE_REMOVED` first, after which `OmCancelDownload()` → `OmWaitForDownload()` → `OmQueryDownload()` rejected the now-not-CONNECTED device with `OM_E_INVALID_DEVICE` and returned *without ever joining*. Every unplug-during-download therefore orphaned a joinable thread still `fread()`ing the dying volume — and `OmShutdown()` then freed the state under it. |
| 3 | **C15** `deviceState->id`/`port`/`root`/`serialId` are filled in before the record is linked into the table; `deviceStatus` stays the last write | A record must never be visible to the reader thread pointing at a half-initialised state. Pairs with `omapi-internal.h` row 1. |
| 4 | **C16** `OmPortOpen()` (non-Windows) sets `c_cc[VMIN] = 0`, `c_cc[VTIME] = 1`; `OmPortReadLine()` sleeps 1 ms on the `c <= 0` path | The port is blocking (the preceding `fcntl(fd, F_SETFL, 0)` clears `O_NDELAY`) and upstream never set the timeout values (its own `#warning` asked about them), so `read()` blocked forever on a wedged device and neither `OmPortReadLine()`'s nor `OmCommand()`'s timeout could ever be evaluated — a battery poll from the UI thread beachballed the app. A *removed* device is the opposite case: `read()` fails immediately (EIO/ENXIO) and the retry loop spun a whole core until the caller's timeout. |
| 5 | **C39** The four `DEBUG:` traces around device attach/detach raised from level 0 to level 2 | `om.debug` defaults to 0, so level-0 messages always fire, and `LibOmapiBackend.start()` deliberately routes the log callback to the user-facing Log pane, `--log-file` transcripts and self-test evidence. These were the only unfiltered upstream debug output on a user surface. |

## `libomapi/src/omapi-download.c`

| # | What | Why |
|---|---|---|
| 1 | **C3** New internal `OmDownloadCancelJoin(OmDeviceState *)`: sets `downloadCancel`, takes the thread handle under `downloadMutex`, clears it, and joins outside the mutex. `OmWaitForDownload()` also clears `downloadThread` after its join | The public `OmCancelDownload()` path refuses a device that is not `om.initialized` *and* `OM_DEVICE_CONNECTED` — which is the state of a device being unplugged, and of *every* device inside `OmShutdown()` (which clears `om.initialized` before walking the table, making its existing cancel a no-op). Both callers then `free()`d the `OmDeviceState` the download thread was still using: use-after-free plus a double `fclose()` on Cmd-Q. The join happens outside the mutex because the download thread's own `OmDoDownloadUpdate()` takes it. Clearing the handle keeps a second cancel/wait from joining twice. |
| 2 | **C13** `OmGetDataFilename()` builds the path with a bounded `snprintf` into a private `OM_MAX_PATH` buffer, NULL-checks the output buffer, empties it before the lookup, and fails (`OM_E_FAIL`) rather than truncating; `OmReaderOpenDeviceData()`'s buffer is `OM_MAX_PATH` rather than a bare `256` | Upstream `strcat`'d `"/CWA-DATA.CWA"` — 13 bytes — onto a device path that `OmGetDevicePath()` can fill to `OM_MAX_PATH - 1` characters, into a buffer `omapi.h:927` documents as `OM_MAX_PATH` and which all four internal callers here declare as exactly that. Reachability was bounded only by how long the FAT volume label happens to be. The signature is deliberately unchanged (no `OmGetDataFilenameN`): the public header is not touched, and the Swift seam's larger buffer stays valid. |

## `libomapi/src/omapi-main.c`

| # | What | Why |
|---|---|---|
| 1 | **C3** `OmShutdown()` calls `OmDownloadCancelJoin(record->state)` unconditionally, dropping the `deviceStatus == OM_DEVICE_CONNECTED` guard | The guard excluded exactly the device that needs the cancel — one unplugged mid-download — and the call it guarded was a no-op anyway, because `om.initialized` is cleared a few lines above. See `omapi-download.c` row 1. |

## `libomapi/src/omapi-status.c`

| # | What | Why |
|---|---|---|
| 1 | **C38** `OmCommand()`: the FW-40 `"COMMIT"` special case is guarded with `expected != NULL` | It `strcmp`'d `expected` twenty lines before the function's own `if (expected == NULL)` check, and `omapi.h` documents the parameter as optional. Latent — no current caller passes NULL — but `OmCommand()` is public API one thin Swift wrapper away. |

## `libomapi/src/omapi-reader.c`

| # | What | Why |
|---|---|---|
| 1 | **C37** `OmReaderNextBlock()` rejects a block (`return 0`) whose axis count is zero, and one whose sample-rate code is 0–3; the sample-rate computation moved above the sample unpacking so the rejection happens first | `(512 - 32) / (numAxes * 2)` and the block-timing divisions by `3200 / (1 << (15 - rateCode))` both divide by a value taken straight from the packet. Zero axes, and every rate code below 4 (whose true rate is under 1 Hz and so truncates to zero), made the divisor zero. arm64's UDIV/SDIV return 0 instead of trapping, so instead of crashing, upstream produced a zero-duration block with a zero rate that `DataLevel.add`'s `guard interval > 0` silently dropped — whole regions of a partly-corrupt file plotted as missing with no diagnostic. Still undefined behaviour. Guarded by `Tests/OmApiTests/OmReaderBlockGuardTests.swift`. |

## `omconvert/`, `cwa-convert/`

No source modifications. Files excluded from vendoring are listed in each `UPSTREAM.md`.
