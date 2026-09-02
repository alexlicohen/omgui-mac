import Foundation
import OmApi

/// The fake devices `--mock` shows.
///
/// The IDs, battery and session values are the ARIA MOP's, so a screenshot taken in mock mode
/// reads like the MOP's own OMGUI screenshots (device `6036222`, 93 %, session 0, "Stopped").
/// They live here rather than in `MockBackend.Spec.defaults` because `Sources/OmApi` is the device
/// layer and its own defaults are what the `OmApi` tests are written against.
public enum MockDeviceCatalog {

    /// The MOP's device: an AX6, charged, cleared, stopped — the state a site's watch is in when
    /// it is plugged in to be configured (MOP §9.4.2).
    public static let mopDeviceId: UInt32 = 6_036_222
    /// A second AX6 that still holds a recording, so "Stopped (with data)" and the greyed-out
    /// Record button (MOP §9.4.2 troubleshooting, §9.4.4) are both reachable.
    public static let mopDeviceWithDataId: UInt32 = 6_036_223
    /// An AX3 on charge, which keeps the AX3-only "Lower Power" / "Unpacked data" boxes and the
    /// battery colour rules exercised.
    public static let mopAx3DeviceId: UInt32 = 6_036_224

    public static let specs: [MockBackend.Spec] = [
        // 6036222 · 93 % · session 0 · no data -> Recording column reads "Stopped".
        MockBackend.Spec(deviceId: mopDeviceId,
                         serialId: "AX617_\(mopDeviceId)",
                         volumeLabel: "AX617_\(mopDeviceId)",
                         port: "/dev/cu.usbmodem-mock\(mopDeviceId)",
                         battery: 93, sessionId: 0,
                         firmware: 53, hardware: 100,
                         config: AccelConfig(rate: .hz100, range: .g8, gyro: .dps2000),
                         dataBlocks: 0, hardwareType: .ax6),

        // 6036223 · holds a recording -> "Stopped (with data)", Record disabled, Download enabled.
        MockBackend.Spec(deviceId: mopDeviceWithDataId,
                         serialId: "AX617_\(mopDeviceWithDataId)",
                         volumeLabel: "AX617_\(mopDeviceWithDataId)",
                         port: "/dev/cu.usbmodem-mock\(mopDeviceWithDataId)",
                         battery: 97, sessionId: 1,
                         firmware: 53, hardware: 100,
                         config: AccelConfig(rate: .hz100, range: .g16, gyro: nil),
                         metadata: MetadataTools.create([
                            .init("_c", "Boston Children's"),
                            .init("_s", "ARIA-IMPACT"),
                            .init("_sc", "P001"),
                            .init("_p", "left wrist"),
                         ]),
                         dataBlocks: 24, hardwareType: .ax6),

        // 6036224 · an AX3 still charging.
        MockBackend.Spec(deviceId: mopAx3DeviceId,
                         serialId: "CWA17_\(mopAx3DeviceId)",
                         volumeLabel: "AX317_\(mopAx3DeviceId)",
                         port: "/dev/cu.usbmodem-mock\(mopAx3DeviceId)",
                         battery: 42, charging: true, sessionId: 0,
                         dataBlocks: 0, hardwareType: .ax3),
    ]
}
