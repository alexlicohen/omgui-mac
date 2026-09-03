import Foundation
import XCTest
@testable import OmApi

/// A private mock backend + started `OmApi`, torn down with the test.
final class MockHarness {
    let root: URL
    let backend: MockBackend
    let api: OmApi

    init(specs: [MockBackend.Spec] = MockBackend.Spec.defaults,
         downloadSteps: Int = 10,
         downloadDelay: TimeInterval = 0) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omgui-tests-\(UUID().uuidString)", isDirectory: true)
        backend = MockBackend(root: root, specs: specs, resetVolumes: true, persistState: false)
        backend.downloadStepCount = downloadSteps
        backend.downloadStepDelay = downloadDelay
        api = OmApi(backend: backend)
        try api.startup()
        // The mock's clock is the host clock, so upstream's 1.2 s settle and its wait for the
        // packed value to tick would cost seconds per configured device and prove nothing.
        for device in api.devices { device.syncTimeTiming = .fast }
    }

    func device(_ id: UInt32) throws -> OmDevice {
        try XCTUnwrap(api.device(id), "mock device \(id) is missing")
    }

    func tearDown() {
        api.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}

extension MockBackend.Spec {
    /// An AX6 carrying real gyro data, for reader tests.
    static func ax6WithData(blocks: Int = 8, gyro: GyroRange = .dps2000, range: AccelRange = .g8) -> MockBackend.Spec {
        MockBackend.Spec(deviceId: 5678, serialId: "AX617_05678", volumeLabel: "AX617_05678",
                         port: "/dev/cu.usbmodem-mock5678", battery: 93, sessionId: 77,
                         firmware: 53, hardware: 100,
                         config: AccelConfig(rate: .hz100, range: range, gyro: gyro),
                         metadata: MetadataTools.create([.init("_sc", "P002")]),
                         start: .zero, stop: .infinite,
                         dataBlocks: blocks, hardwareType: .ax6)
    }
}
