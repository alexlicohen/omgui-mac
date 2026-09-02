# OMGUI / AX3-AX6 verified facts (research 2026-09-02)

## OMGUI
- Repo: github.com/digitalinteraction/openmovement (alias openmovementproject/openmovement), source `Software/OM/omgui/`.
- .NET Framework v3.5, WinForms (`omgui.csproj`: WinExe, TargetFrameworkVersion v3.5). BSD 2-clause.
- Latest release AX3-GUI-45 (2022-10-31). Windows XP SP3+; bundled USB drivers; InnoSetup installer.
- OMGUI does no device discovery itself: it calls libomapi (OMAPI) via `omapinet` (C# P/Invoke). libomapi has per-platform finders: `omapi-devicefinder-win.cpp` / `-mac.c` / `-linux.c`.
- Official Mac guidance (wiki AX3-GUI): "OmGui can be installed using virtualization software (such as Parallels on Mac)"; axconfig is the "experimental, cross-platform" alternative.

## AX3/AX6 host interface (Docs/ax3/ax3-technical.md)
- USB composite: Mass Storage (serves `CWA-DATA.CWA`) + USB CDC serial (query/configure). USB serial number prefix `CWA` (AX3) / `AX6` (AX6). VID:PID 04d8:0057.
- Protocol: 7-bit ASCII, CR/LF delimited.
  - `SESSION <id>` (0..2^31); `HIBERNATE <YYYY-MM-DD,hh:mm:ss>|0|-1` (start; 0=always, -1=never); `STOP <..>|0|-1`
  - `RATE <code>[,<gyro-range>]`: freq = 3200/(1<<(15-(code&0x0f))) Hz; range bits 0=±16g,64=±8g,128=±4g,192=±2g; +16 low power; gyro 125–2000 dps (AX6)
  - `TIME <YYYY-MM-DD,hh:mm:ss>`; `ID` (type, hw/fw version, device id); `SAMPLE 1` (battery); `COMMIT`
  - `FORMAT {Q|W}[C]` (Q quick, W full NAND wipe, C commit after) — drive ejects then re-inserts
  - `STREAM`, `RESET` (bootloader), `LED <n>`, `ECC 0|1`, `ANNOTATE..`, `MAXSAMPLES`
- macOS: libomapi mac finder expects `/dev/tty.usbmodem*`, `/dev/cu.usbmodem*` and volume `/Volumes/AX317_?????` (IOKit + DiskArbitration). AX6 volume label differs — detect by `CWA-DATA.CWA` presence.

## Cross-platform pieces
- libomapi: github.com/openmovementproject/libomapi — C, macOS/Linux/Windows; bindings C#/Java/Node/Python(untested)/Rust(untested). Docs openmovement.dev/omapi/html/.
- openmovement-axconfig (config.openmovement.dev, BSD-2): WebUSB on Mac / Web Serial elsewhere; configure only; no download; wipe via hidden `#diagnostics` page.
- omconvert / cwa-convert: portable C in `Software/AX3/`.
- openmovement-python: `cwa_metadata.py`, `CwaData`, `omconvert.py` (read-only).
- No official Axivity macOS software exists.

## Not verified
- Exact byte-level behaviour of OM_ERASE_WIPE vs OM_ERASE_QUICKFORMAT in libomapi C.
- Whether the libomapi mac device finder still builds/works on macOS 26 (deprecated IOKit/DA APIs likely).
