# omgui-mac

A native Apple Silicon macOS port of [Axivity OMGUI](https://github.com/digitalinteraction/openmovement),
the Windows configuration and download tool for AX3 and AX6 accelerometers.

**Status: phases 0–1 (core library, vendoring, build system). No GUI yet.**
This repository currently gives you a Swift package — `OmApi` — and a command-line tool,
`omgui-cli`. The SwiftUI/AppKit app that mirrors OMGUI's window comes in a later phase.

## Why

ARIA IMPACT sites have to configure AX6 watches, download `CWA-DATA.CWA`, and clear devices.
OMGUI is Windows-only, and none of the usual escape hatches work on an Apple Silicon Mac:
containers have no USB passthrough on macOS, Wine does not emulate the WMI/SetupAPI pairing OMGUI
uses to match a serial port to its mass-storage volume, and Rosetta 2 is going away after
macOS 27. A Windows VM works but needs a licence, ~40 GB, and admin rights.

OMGUI itself is a thin WinForms shell over `libomapi`, a BSD-2 C library that already ships a
macOS backend, and every analysis tool it offers is `omconvert`/`cwa-convert` — portable C. So
the port links the same C library rather than reimplementing the serial protocol, and bundles
arm64 builds of the same helper binaries. Behaviour matches OMGUI because it is largely the same
code underneath.

See `refs/00-plan.md` for the full plan and `refs/03-omgui-ui-inventory.md` for the OMGUI feature
inventory the port is measured against.

## Layout

```
Package.swift            SwiftPM manifest (macOS 14+, arm64, Swift 6 language mode)
Vendor/libomapi/         Vendored libomapi C sources -> the COmApi target
Vendor/omconvert/        Vendored omconvert sources  -> build/helpers/omconvert
Vendor/cwa-convert/      Vendored cwa-convert sources-> build/helpers/cwa-convert
Vendor/PATCHES.md        Every local change to vendored code, and why
Sources/OmApi/           Swift API mirroring upstream omapinet
Sources/omgui-cli/       Command-line front end
Tests/OmApiTests/        XCTest suite
scripts/build-helpers.sh Builds the arm64 helper binaries
refs/                    Plan, device facts, OMGUI inventory, phase-1 notes
```

## Build

```sh
swift build -c release          # library + CLI
swift test                      # unit tests
bash scripts/build-helpers.sh   # omconvert + cwa-convert into build/helpers/
```

Requires macOS 14 or later on Apple Silicon and a Swift 6 toolchain (developed on Swift 6.3 /
Xcode 26.6 / macOS 26.6). There are no external package dependencies and nothing from Homebrew.
Details in [`docs/BUILD.md`](docs/BUILD.md).

## Mock mode

Every command works without hardware. `--mock` (or `OMGUI_MOCK=1`) swaps the libomapi backend for
`MockBackend`, which creates real directories standing in for mounted volumes, each holding a
real `CWA-DATA.CWA` written to the AX3/AX6 binary format. That means the mock exercises the same
file parser — and the same `omconvert` — that hardware would.

```sh
$ swift run omgui-cli status --mock
Device  Session Id  Battery  Download  Recording            Group
01234   0000000001  87%                Stopped (with data)  Devices
05678   0000000000  100%               Stopped              Standby
09999   0000000000  47%                Stopped              Charging
```

Three fake devices: an AX3 holding a finished recording, a charged AX6 with a gyroscope, and an
AX3 still charging (its battery climbs on each poll, so it moves Charging → Standby). Their fake
volumes live under `$TMPDIR/omgui-mac-mock` unless `OMGUI_MOCK_ROOT` says otherwise, and their
settings persist between invocations, so `record --mock` is visible to the next `status --mock`.

## CLI

```
omgui-cli status   [--long] [--device ID]... [--mock]
omgui-cli identify [--led N] [--device ID]... [--mock]
omgui-cli record   --session N [--rate HZ] [--range G] [--gyro DPS] [--low-power]
                   [--immediate | --start "YYYY-MM-DD HH:MM:SS" --stop "..."]
                   [--flash] [key=value]... [--device ID]... [--mock]
omgui-cli download --workspace DIR [--template T] [--overwrite] [--device ID]... [--mock]
omgui-cli clear    [--quick] [--device ID]... [--mock]
```

`record` runs OMGUI's exact commit order (session id → metadata → max samples → accelerometer
config → time sync → flash setting → delays, which is the call that commits). `download` writes
`<name>.cwa.part` and renames on success, with OMGUI's filename template and device/session
cross-check. `clear` defaults to a full NAND wipe; `--quick` is OMGUI's Shift-click quick format.

Exit codes: `0` success, `1` usage error, `2` no devices found, `3` operation failed.

```sh
swift run omgui-cli record --mock --session 42 --rate 100 --range 8 --gyro 2000 \
    StudyCode=ARIA-IMPACT SubjectCode=P001 SubjectSite="left wrist"
swift run omgui-cli download --mock --workspace ~/Desktop/cwa
```

## Licence

BSD 2-clause, matching upstream Open Movement. Vendored sources keep their own `LICENSE.TXT`
and record their upstream commit in `UPSTREAM.md`.
