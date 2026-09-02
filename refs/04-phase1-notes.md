# Phase 0/1 notes — core library, vendoring, build system

Everything below was verified on this machine (macOS 26.6, Xcode 26.6, Swift 6.3, arm64) unless
marked UNVERIFIED. No hardware was available, so every device-side claim is UNVERIFIED by
construction and is listed under "Risks for real-hardware testing".

## Decisions

**SwiftPM only, no `.xcodeproj`.** `Package.swift` at tools-version 6.0, `platforms: [.macOS(.v14)]`.
The C target points `path:` straight at `Vendor/libomapi`, so the vendored tree is the build tree
and there is no copy step to drift. The `.app` bundle gets assembled by a script in a later phase.

**Swift 6 language mode everywhere, including the C interop layer.** No Swift 5 fallback was
needed. The pattern that made it work: libomapi's callbacks are `@convention(c)` function pointers
that cannot capture, so the backend passes `Unmanaged<LibOmapiBackend>.passUnretained(self)
.toOpaque()` as libomapi's user reference and recovers `self` inside the trampoline. Every type
that crosses a thread (`LibOmapiBackend`, `MockBackend`, `OmApi`, `OmDevice`) is a
`final class … @unchecked Sendable` with an explicit lock around its mutable state, which is the
honest description of what libomapi's threading model actually is. The single global —
`LibOmapiBackend.current`, enforcing that only one backend owns libomapi's process-wide callback
slots — is `nonisolated(unsafe)` behind its own lock.

**Link libomapi, do not reimplement.** Confirmed still the right call: the whole C library
compiles on macOS 26 with `-Wall` and, after the patches below, zero warnings. Nothing needed a
Swift reimplementation.

**`DeviceBackend` protocol with two implementations.** `LibOmapiBackend` is a mechanical
translation of the `omapi.h` calls `omapinet` uses; `MockBackend` is a full in-process fake.
Everything above the protocol (`OmApi`, `OmDevice`, `OmReader`, the CLI) is backend-agnostic.
`OmReader` is the deliberate exception: it always uses libomapi's C reader, because the mock
writes *real* CWA files, so mock mode exercises the same parser hardware would.

**Mock fidelity.** `CwaWriter` writes the binary layout from `Docs/ax3/cwa.h` and
`ax3-technical.md`. Proof it is real rather than merely self-consistent: the vendored
`build/helpers/omconvert` and `build/helpers/cwa-convert` both parse a mock device's
`CWA-DATA.CWA` and emit the expected 1950-row CSV at 10 ms intervals with the exact sample values
`CwaWriter` encoded.

## The one real bug found in libomapi

`typedef unsigned long OM_DATETIME;` — 32-bit on Windows (and declared `uint` in the C# binding),
**64-bit on macOS**. `OM_DATETIME` is a member of the tightly-packed `OM_READER_DATA_PACKET` and
`OM_READER_HEADER_PACKET`, so on any LP64 build the structs were the wrong size and every field
after `timestamp` was displaced by four bytes. Measured before the fix:

```
sizeof(OM_READER_DATA_PACKET) = 516   (spec: 512)
light@22 temp@24 events@26 batt@27 rate@28 axes@29 tsOff@30 count@32 raw@34 csum@514
                        (spec:  18      20        22       23       24       25       26       28      30       510)
sizeof(OM_READER_HEADER_PACKET) = 1032 (spec: 1024), annotation@72 (spec: @64)
```

`OmReaderGetValue()` reads through that struct, so `OM_VALUE_LIGHT`, `_TEMPERATURE`, `_EVENTS`,
`_BATTERY`, `_SAMPLERATE` and every cooked `_MC` / `_MV` / `_PERCENT` value were garbage — exactly
the values `omapinet`'s `OmReader.ReadBlock()` exposes and OMGUI's DataViewer plots. Pinned to
`uint32_t`; all offsets now match the spec. `OM_DATETIME_INFINITE` becomes `0xFFFFFFFF`, still
above `OM_DATETIME_MAX_VALID` (`0xFF3F7EFB`), so the `HIBERNATE`/`STOP` sentinels are unaffected.
Guarded by `COmApiLayoutTests`, which round-trips a `CwaWriter` block through the C structs.

This bug is invisible on Windows, which is presumably why it survived: upstream's own macOS
build (`src/Makefile`) compiles with `-w`, so it produces no diagnostics at all.

## `omapi-devicefinder-mac.c` audit

Against `refs/01-omgui-and-device-facts.md`:

* **VID:PID `04d8:0057`** — correct as vendored (`#define VID 0x04D8` / `PID 0x0057`), matched via
  `kUSBVendorID`/`kUSBProductID` on an `IOUSBHostDevice` service. Unchanged.
* **Serial prefixes `CWA` / `AX6`** — the finder does *not* filter on them, and should not: the
  VID/PID match is the discriminator, and `DeviceIdFromSerialNumber()` correctly takes the trailing
  digit run, so `CWA17_01234` and `AX617_01234` both yield `1234`. The prefix matters only for
  AX6 detection, which belongs in the Swift layer (`DeviceInfo.hasSyncGyro`, mirroring
  `OmDevice.HasSyncGyro`: `AX6` or the `CWA64` prototype firmware). No change.
* **`/dev/cu.usbmodem*`** — correct. `findSerial()` matches `kIOSerialBSDServiceValue` services and
  reads `kIOCalloutDeviceKey`, which *is* the `cu.` node, then correlates on the
  `USB Serial Number` property. No change beyond the deprecation and leak fixes.
* **Volume by `CWA-DATA.CWA`, not by the `AX317_` label** — this needed the real work. Upstream
  recovered the volume *name* by string-scanning `CFCopyDescription()` output (with a stray
  `if (isdigit(*p)) *p = 'x';` that corrupts any name starting with a digit), assumed the mount
  point was `/Volumes/<name>`, and assumed the data partition was always `<disk>s1`. All three are
  wrong in ways that would bite: a volume name is not a mount point (the mounter appends ` 1` on
  collision), some units present a superfloppy with no partition table, and the AX6 does not use
  the `AX317_` label. `findMount()` is rewritten to ask DiskArbitration for the real mount path
  (`kDADiskDescriptionVolumePathKey`), try the whole disk plus partitions 1–4, and select by the
  presence of `CWA-DATA.CWA`. A mounted volume without the file is accepted only after ~3 s of
  polling and logs a warning (covers the window just after a `FORMAT`).

Also fixed there: `kIOMasterPortDefault` → `kIOMainPortDefault`; a `SIGINT` handler that called
`exit(0)` from library code; `CFRunLoopStop` + `pthread_cancel` → `CFRunLoopStop` + `thread_join`;
a dead `osVersion()` whose Darwin→macOS mapping (`major - 9`) broke at macOS 26; several CF leaks;
a `deviceId <= 0` test that could never fire on an unsigned. Full table in `Vendor/PATCHES.md`.

Discovery latency dropped from a worst case of ~22 s per device (2 s + 20 s of blocking sleeps on
the notification thread) to ~8 s, and the wait now observes `om.quitDiscoveryThread`.

## POSIX audit of the rest of libomapi

Checked `omapi-download.c`, `omapi-reader.c`, `omapi-settings.c`, `omapi-status.c`,
`omapi-internal.c` for the failure modes that break C written against Win32:

* **Large files** — clean. `OmReaderState.dataOffset`/`fileSize` are `long` (64-bit on macOS) and
  `ftell`/`fseek` are the LFS-correct forms there. `OmGetDataFileSize()` returns `int`, which caps
  at 2 GB; the AX3's NAND is ~512 MB, so it is fine, but it is a latent limit worth knowing.
* **Path handling** — `OmGetDataFilename()` already has a `#if !defined(_WIN32)` branch that joins
  with `/`. Correct.
* **Open flags** — `OmPortOpen()` uses `O_NOCTTY | O_NDELAY` then clears `O_NONBLOCK` with
  `fcntl(fd, F_SETFL, 0)`, which is the required incantation for `/dev/cu.*` on macOS (otherwise
  `open()` blocks on carrier detect). `termios` is configured raw, 8N1, `CLOCAL|CREAD`. Correct.
* **`fsync`** — not used, and not needed: downloads go through `fopen`/`fwrite`/`fclose` to a
  local file, and the `.part` → final rename happens after `fclose`.
* One genuine defect: non-Windows `OmPortOpen()` had
  `if (infile == NULL && infile[0] == '\0')`, which dereferences the pointer it just established
  is `NULL`. Unreachable from current callers (they pass a `char[]` field), fixed anyway.

Not fixed, recorded instead: `getUSBStringDescriptor()` and `findSerial()` return `malloc`ed
strings the caller never frees (one small leak per device attach), and a `DeviceData` that fails
mid-enumeration leaks its `deviceName`. Bounded and harmless for an app that sees a handful of
devices per session; fixing them means touching ownership across three functions, which is not
worth the diff before hardware testing.

## Deviations from the brief, and why

* **Metadata key order.** The brief lists `_s _c _i _x _so _n _sc _se _h _w _ha _p _sn`. The
  authoritative source, `DateRangeForm.cs` lines 474–487 (matching `MetaDataTools.mdStringList`),
  is `_c _s _i _x _so _n _p _sc _se _h _w _ha _sn` — `_c` before `_s`, and `_p` before `_sc`
  rather than after `_ha`. Order is load-bearing because `CreateMetaData` concatenates in list
  order, so the encoded string differs. Implemented as OMGUI has it.
* **`HasNewData`.** OMGUI reads the Windows *archive* attribute, which macOS does not have.
  `OmDevice.hasNewData` instead tracks whether this session has downloaded the device since its
  data file appeared. Note that upstream's `OmDevice.Category` has a standing `TODO` that
  overwrites `SourceCategory.NewData` with `Other`, so OMGUI never actually shows its "New Data"
  group; `category` reproduces that exactly and `strictCategory` exposes the pre-TODO value for
  phase 2 to choose.
* **`OmDevice.SyncTime`.** Upstream busy-spins a whole CPU core waiting for the second to roll
  over (`while (...) { volatileTemp++; }`). Replaced with a computed sleep to the next boundary;
  the verification logic (set, wait, read back, require within 5 s, retry up to 12 times) is kept.
* **Download log.** OMGUI optionally appends `yyyy-MM-dd HH:mm:ss,DOWNLOAD-OK,<filename>` to a
  configured log file. The CLI prints `DOWNLOAD-OK` but does not maintain the file; that setting
  belongs with the rest of the workspace profile in phase 2.

## Risks for real-hardware testing (phase 5)

1. **The rewritten `findMount()` has never seen a device.** The two things to watch: whether
   `IORegistryEntrySearchCFProperty(kIOBSDNameKey)` returns the whole disk or a partition node on
   macOS 26 (both are handled, but only one path will actually run), and whether the AX6 mounts
   fast enough for the ~8 s budget. Run with `OMDEBUG=3` — the `MAC: ...` trace prints the BSD
   name, each candidate, and the chosen mount.
2. **Removable-volume privacy prompt.** macOS 13+ asks "…would like to access files on a
   removable volume" the first time a process reads a mounted USB volume. libomapi reads
   `CWA-DATA.CWA` from the discovery thread, before any UI exists. If the prompt is denied or
   never answered, discovery silently reports no device. UNVERIFIED whether this fires for
   `/Volumes` mounts of a mass-storage class device; it must be checked before the SOP is written,
   and phase 4 needs `NSRemovableVolumesUsageDescription` in the app's `Info.plist`.
3. **Serial port exclusivity.** libomapi opens `/dev/cu.*` without `TIOCEXCL`. Two copies of the
   app, or the app plus a terminal session, can interleave commands on the same device. Worth
   adding once hardware confirms the port names.
4. **`FORMAT` re-enumeration.** `OM_ERASE_WIPE`/`QUICKFORMAT` make the drive eject and re-insert
   (`ax3-technical.md`). Whether that arrives as a removed+connected pair, and how long the NAND
   wipe takes before the volume returns, is unknown. The mock cannot model it. This is the most
   likely place for the Clear flow to misbehave on real hardware.
5. **Byte-level `OM_ERASE_WIPE` vs `OM_ERASE_QUICKFORMAT`** is still UNVERIFIED (carried over from
   `refs/01`). OMGUI's default is the full wipe and Shift-click is the quick format; the SOP has
   to state which sites should use.
6. **Header parity.** The objective equivalence check is still a byte diff of an OMGUI-produced
   `.cwa` header against one this port produces for the same settings, via
   `openmovement-python`'s `cwa_metadata.py` on both. Needs a sample file from Abby.
7. **AX6 firmware quirks.** `DateRangeForm` carries warnings for firmware ≤ 53 at 800–1600 Hz,
   for any rate above 1600 Hz with a gyro, and for gyro below 25 Hz. Those live in the UI layer
   and are not implemented yet — phase 2 must port them, and phase 5 should confirm the firmware
   version the ARIA kits ship with.

## Test coverage

75 XCTest cases, all green. Metadata encode/decode vectors were derived by hand-tracing
`MetaDataTools.cs` rather than by running this implementation (space, `&`, apostrophe, UTF-8
`ü`/`é`/`中`, empty and whitespace-only fields, truncated `%` escapes, key ordering, the 448-byte
annotation block and its 14 segments). Accelerometer coverage is exhaustive: every OMGUI frequency
(3200…6.25) × every range (2/4/8/16) × every gyro range (off/125…2000), each checked against the
device-side formulas in `ax3-technical.md`. The rest: filename-template vectors including
sanitising, mock record/download/clear flows, and `OmReader` against `CwaWriter` fixtures for both
AX3 and AX6.
