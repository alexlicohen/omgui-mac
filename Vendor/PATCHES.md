# Local modifications to vendored sources

Every edit is marked in the source with `PATCH (omgui-mac)`. Baseline commits are in each
directory's `UPSTREAM.md`. Nothing outside this list was changed.

Verification: each file compiles with `clang -c -arch arm64 -Wall -I Vendor/libomapi/include`
with **zero warnings and zero errors** on Xcode 26.6 / macOS 26.6 (arm64).

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

Not changed, recorded as findings instead (see `refs/04-phase1-notes.md`):
`getUSBStringDescriptor()` returns a pointer into a `malloc(128)` buffer that the caller never
frees (one leak per device attach, bounded and small); `findSerial()`'s returned string is also
never freed; `DeviceData` for a device that fails mid-enumeration leaks its `deviceName`.

## `libomapi/src/omapi-internal.c`

| # | What | Why |
|---|---|---|
| 1 | `OmPortOpen()` (non-Windows): `if (infile == NULL && infile[0] == '\0')` → `\|\|` | The `&&` form dereferences `infile` after establishing it is `NULL`. Unreachable today (callers pass a `char[]` field), but it is a NULL dereference as written. |

## `omconvert/`, `cwa-convert/`

No source modifications. Files excluded from vendoring are listed in each `UPSTREAM.md`.
