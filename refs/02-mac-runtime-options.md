# Why a native port (Apple Silicon runtime assessment, 2026-09-02)

| Strategy | Feasible | Notes |
|---|---|---|
| Containers (Docker/Podman/Apptainer) | NO | Linux VM, no USB passthrough on macOS (docker/for-mac #6844); USB/IP has no macOS server. Conversion only. |
| Wine / CrossOver | unverified, expiring | x86 Wine under Rosetta 2 (native ARM64 CrossOver only previewed 2026-07). OMGUI pairs serial+volume via WMI/SetupAPI which Wine lacks. Rosetta 2 ends after macOS 27. |
| Windows 11 ARM64 VM | YES (fallback) | VMware Fusion free since 2024-11; Parallels ~$150/seat/yr, MS-authorized; UTM USB passthrough only on flaky QEMU backend. Needs Windows license, ~30–40 GB, admin. Do not redistribute VM images. |
| Windows 365 / AVD | NO | macOS client has no USB redirection. |
| Dedicated mini-PC | YES | ~$110–200/site; logistics. |
| Native app on libomapi / serial protocol | YES (chosen) | Device is a plain CDC serial + mass storage; libomapi has a mac backend; omconvert is portable C. |

Distribution: Developer ID + notarization (paid account available) → double-click DMG install, no Gatekeeper prompt, no Terminal.
