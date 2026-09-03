import COmApi
import Darwin
import Foundation
import XCTest

/// The C-layer shutdown/removal protocol (`refs/12-deep-review-2.md` H1-H4, `Vendor/PATCHES.md`).
///
/// The redesign rests on one contract: a download thread publishes `downloadFinished` as the last
/// thing it does with its `OmDeviceState`, and nothing frees that state -- or destroys a mutex the
/// thread can still take -- until it has. Everything else follows from it. The IOKit removal
/// callback only *requests* cancellation, because a join there blocks the run loop that delivers
/// attach/detach events and processes `CFRunLoopStop()`; `OmShutdown()` performs the one
/// authoritative join and bounds it, leaking the state rather than freeing it under a live thread.
///
/// None of that is reachable through the public API without an AX3/AX6 attached: `OmBeginDownloading`
/// needs a started library, a discovered device and a seekable file. `Vendor/libomapi/src/omapi-testhook.c`
/// therefore stands a real `OmDeviceState` up over a caller-supplied descriptor and runs the real
/// `OmDownloadThread()` over it; the thread is stopped and released at known points from inside its
/// own chunk callback. The functions under test below are the ones the removal callback and
/// `OmShutdown()` call, not stand-ins.
///
/// The hooks are bound with `@_silgen_name` because `Vendor/libomapi/include` holds only the public
/// `omapi.h`, and the vendored public header is deliberately not extended for a test.

// MARK: - Bindings to the vendored C layer

@_silgen_name("OmTestBegin")
private func omTestBegin() -> Int32

@_silgen_name("OmTestEnd")
private func omTestEnd()

@_silgen_name("OmTestDeviceCreate")
private func omTestDeviceCreate(_ deviceId: UInt32, _ sourceFd: Int32,
                                _ destPath: UnsafePointer<CChar>?, _ blocksTotal: Int32) -> OpaquePointer?

@_silgen_name("OmTestDownloadStart")
private func omTestDownloadStart(_ device: OpaquePointer) -> Int32

@_silgen_name("OmTestDownloadFinished")
private func omTestDownloadFinished(_ device: OpaquePointer) -> Int32

@_silgen_name("OmTestDownloadStreamsClosed")
private func omTestDownloadStreamsClosed(_ device: OpaquePointer) -> Int32

@_silgen_name("OmTestDownloadStatus")
private func omTestDownloadStatus(_ device: OpaquePointer) -> Int32

@_silgen_name("OmTestDownloadThreadActive")
private func omTestDownloadThreadActive(_ device: OpaquePointer) -> Int32

/// What `OmDeviceDiscovery(OM_DEVICE_REMOVED, ...)` calls on the IOKit run-loop thread.
@_silgen_name("OmDownloadRequestCancel")
private func omDownloadRequestCancel(_ device: OpaquePointer)

@_silgen_name("OmDownloadWaitFinished")
private func omDownloadWaitFinished(_ device: OpaquePointer, _ timeoutMs: UInt) -> Int32

/// What `OmShutdown()` calls: bounded, and zero means "this state may not be freed".
@_silgen_name("OmDownloadJoinBounded")
private func omDownloadJoinBounded(_ device: OpaquePointer, _ timeoutMs: UInt) -> Int32

private let omOK: Int32 = 0

/// A gate the download thread parks on, from inside its own chunk callback -- the one place a test
/// can stop that thread at a known point and keep it stopped. It stands in for the real hazard: a
/// download thread that is not going to come back inside the shutdown's budget, whether because it
/// is inside a read from a volume that has just been yanked or anywhere else.
private let downloadGate = DispatchSemaphore(value: 0)
private let downloadGateEntered = DispatchSemaphore(value: 0)

final class LibOmapiDownloadProtocolTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omapi-download-protocol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        XCTAssertEqual(omTestBegin(), omOK, "the library was already started by another test")
    }

    override func tearDownWithError() throws {
        _ = OmSetDownloadChunkCallback(nil, nil)
        downloadGate.signal()                       // release anything still parked in the callback
        omTestEnd()                                 // cancels and reaps, exactly as OmShutdown does
        while downloadGate.wait(timeout: .now()) == .success {}
        while downloadGateEntered.wait(timeout: .now()) == .success {}
        try? FileManager.default.removeItem(at: scratch)
        scratch = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func destinationPath(_ name: String) -> String {
        scratch.appendingPathComponent(name).path
    }

    private func makeSourceFile(_ name: String, blocks: Int) throws -> Int32 {
        let url = scratch.appendingPathComponent(name)
        try Data(repeating: 0xA5, count: blocks * 512).write(to: url)
        let fd = open(url.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0, "could not open the source fixture")
        return fd
    }

    private func makeDevice(_ id: UInt32, sourceFd: Int32, destination: String, blocks: Int32)
        throws -> OpaquePointer
    {
        let device = destination.withCString { omTestDeviceCreate(id, sourceFd, $0, blocks) }
        return try XCTUnwrap(device, "OmTestDeviceCreate failed")
    }

    // MARK: - H1/H2: the removal path must not join, H3: the shutdown join must be bounded

    /// The case the whole redesign exists for: a download thread that is not going to come back --
    /// in the field, one inside a read from a volume that has just been yanked. The thread is
    /// parked here from inside its own chunk callback, which is the only way a test can stop it at
    /// a known point and *keep* it stopped, so none of the assertions below race it.
    ///
    /// `OmDownloadRequestCancel()` is what the IOKit removal callback calls and must return anyway
    /// (C3 joined there, which is why an unplug mid-download wedged discovery and then let
    /// `OmShutdown()` free the state under two live threads). `OmDownloadJoinBounded()` is what
    /// `OmShutdown()` calls and must give up rather than block, reporting that the state may *not*
    /// be freed -- and must go on reporting that until the thread really lets go.
    func testRequestCancelDoesNotJoinAndTheBoundedJoinGivesUpRatherThanBlocking() throws {
        let sourceFd = try makeSourceFile("stuck.bin", blocks: 512)
        let device = try makeDevice(900_001, sourceFd: sourceFd,
                                    destination: destinationPath("stuck.cwa"), blocks: 512)

        _ = OmSetDownloadChunkCallback({ _, _, _, _, _ in
            downloadGateEntered.signal()
            downloadGate.wait()
        }, nil)

        XCTAssertEqual(omTestDownloadStart(device), omOK)
        XCTAssertEqual(downloadGateEntered.wait(timeout: .now() + 5.0), .success,
                       "the download thread never reached the chunk callback")

        // The removal callback's call. It must not wait for the thread.
        let cancelStarted = Date()
        omDownloadRequestCancel(device)
        XCTAssertLessThan(Date().timeIntervalSince(cancelStarted), 1.0,
                          "OmDownloadRequestCancel() blocked -- on the IOKit thread that is a wedged run loop")
        XCTAssertEqual(omTestDownloadFinished(device), 0, "the parked thread cannot have finished")

        // OmShutdown()'s call. It must give up on its budget and refuse to free the state.
        let joinStarted = Date()
        XCTAssertEqual(omDownloadJoinBounded(device, 250), 0,
                       "the bounded join reported a parked thread as finished -- OmShutdown() would free its state")
        let joinElapsed = Date().timeIntervalSince(joinStarted)
        XCTAssertGreaterThanOrEqual(joinElapsed, 0.2, "the join did not wait for its budget")
        XCTAssertLessThan(joinElapsed, 5.0, "the join was not bounded by its budget")

        // Detaching the handle must not make a second reap think the state became free-able.
        XCTAssertEqual(omDownloadJoinBounded(device, 100), 0,
                       "a reap after a detach declared the state free-able while the thread still holds it")

        // Releasing the thread lets it run its epilogue; only now is the state free-able.
        downloadGate.signal()
        XCTAssertEqual(omDownloadWaitFinished(device, 5000), 1,
                       "the thread never published downloadFinished")
        XCTAssertEqual(omDownloadJoinBounded(device, 1000), 1)
        XCTAssertEqual(omTestDownloadThreadActive(device), 0)
        XCTAssertEqual(omTestDownloadStreamsClosed(device), 1,
                       "the epilogue left downloadSource/downloadDest set -- a second cancel would fclose() twice")
        XCTAssertEqual(omTestDownloadStatus(device), OM_DOWNLOAD_CANCELLED.rawValue)
    }

    // MARK: - H3: the finished flag is the epilogue's last act

    /// The happy path pins the contract the shutdown relies on: by the time `downloadFinished` is
    /// visible the streams are closed, the final status is published, and the join is immediate.
    func testACompletedDownloadClosesBothStreamsAndPublishesFinished() throws {
        let sourceFd = try makeSourceFile("complete.bin", blocks: 8)
        let destination = destinationPath("complete.cwa")
        let device = try makeDevice(900_002, sourceFd: sourceFd, destination: destination, blocks: 8)

        XCTAssertEqual(omTestDownloadStart(device), omOK)
        XCTAssertEqual(omDownloadJoinBounded(device, 5000), 1, "a 4 KB copy did not finish in 5 s")

        XCTAssertEqual(omTestDownloadFinished(device), 1)
        XCTAssertEqual(omTestDownloadThreadActive(device), 0, "the joined thread was not marked reaped")
        XCTAssertEqual(omTestDownloadStreamsClosed(device), 1)
        XCTAssertEqual(omTestDownloadStatus(device), OM_DOWNLOAD_COMPLETE.rawValue)

        let written = try Data(contentsOf: URL(fileURLWithPath: destination))
        XCTAssertEqual(written.count, 8 * 512, "the destination was not flushed before the thread finished")
    }

    // MARK: - H2: the cancel flag stops the copy loop

    /// Cancellation is raised from the download thread's own chunk callback, so the copy loop is
    /// provably between reads when the flag goes up and the outcome is `CANCELLED` rather than a
    /// race between the flag and the invalidated descriptor.
    func testCancellingMidCopyEndsTheDownloadCancelledAndReleasesTheState() throws {
        // 512 blocks against a 256-block read: the loop must come back round for a second chunk.
        let sourceFd = try makeSourceFile("cancel.bin", blocks: 512)
        let device = try makeDevice(900_003, sourceFd: sourceFd,
                                    destination: destinationPath("cancel.cwa"), blocks: 512)

        _ = OmSetDownloadChunkCallback({ reference, _, _, _, _ in
            guard let reference else { return }
            omDownloadRequestCancel(OpaquePointer(reference))
        }, UnsafeMutableRawPointer(device))

        XCTAssertEqual(omTestDownloadStart(device), omOK)
        XCTAssertEqual(omDownloadJoinBounded(device, 5000), 1)

        XCTAssertEqual(omTestDownloadStatus(device), OM_DOWNLOAD_CANCELLED.rawValue,
                       "the copy loop did not observe downloadCancel")
        XCTAssertEqual(omTestDownloadFinished(device), 1)
        XCTAssertEqual(omTestDownloadStreamsClosed(device), 1)
        XCTAssertEqual(omTestDownloadThreadActive(device), 0)
    }

    // MARK: - H2/H3: the Cancel button's join is bounded too

    /// `OmCancelDownload` is the *other* main-thread join -- OmGui calls it from
    /// `@MainActor AppModel.cancelDownload()`. Upstream raised the cancel flag outside
    /// `om.downloadMutex` and then waited on the thread with no bound, which is H3's failure
    /// reached through the Cancel button rather than through Cmd-Q: in the window between a device
    /// being yanked and IOKit delivering `kIOMessageServiceIsTerminated` the download thread is
    /// parked in `fread()` on a volume that is gone, and the main thread blocked until the kernel
    /// timed the read out. It must come back on its budget and report that the thread has not
    /// stopped.
    func testCancelDownloadIsBoundedAndReportsAThreadThatHasNotStopped() throws {
        let sourceFd = try makeSourceFile("cancel-bounded.bin", blocks: 512)
        let device = try makeDevice(900_005, sourceFd: sourceFd,
                                    destination: destinationPath("cancel-bounded.cwa"), blocks: 512)

        _ = OmSetDownloadChunkCallback({ _, _, _, _, _ in
            downloadGateEntered.signal()
            downloadGate.wait()
        }, nil)

        XCTAssertEqual(omTestDownloadStart(device), omOK)
        XCTAssertEqual(downloadGateEntered.wait(timeout: .now() + 5.0), .success,
                       "the download thread never reached the chunk callback")

        let started = Date()
        XCTAssertEqual(OmCancelDownload(900_005), OM_E_ABORT,
                       "OmCancelDownload declared a parked thread stopped")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10.0,
                          "OmCancelDownload was not bounded -- on the main thread that is a beachball")

        // Releasing the thread lets its epilogue run; only then does the state become reapable.
        downloadGate.signal()
        XCTAssertEqual(omDownloadWaitFinished(device, 5000), 1,
                       "the thread never published downloadFinished")
        XCTAssertEqual(omTestDownloadStatus(device), OM_DOWNLOAD_CANCELLED.rawValue,
                       "the copy loop did not observe the cancel OmCancelDownload requested")
        XCTAssertEqual(omTestDownloadStreamsClosed(device), 1)
    }

    // MARK: - H1: a cancelled-but-unjoined thread is reaped by the next download, not leaked

    /// The removal path deliberately leaves the thread running. Whoever comes next has to collect
    /// it: `OmShutdown()`, or the device's next `OmBeginDownloading()`. Without that, `thread_create`
    /// would overwrite -- and permanently leak -- a joinable handle on every unplug/replug.
    func testASecondDownloadReapsTheFirstThreadRatherThanOverwritingItsHandle() throws {
        let sourceFd = try makeSourceFile("first.bin", blocks: 8)
        let device = try makeDevice(900_004, sourceFd: sourceFd,
                                    destination: destinationPath("first.cwa"), blocks: 8)

        XCTAssertEqual(omTestDownloadStart(device), omOK)
        XCTAssertEqual(omDownloadWaitFinished(device, 5000), 1)
        XCTAssertEqual(omTestDownloadThreadActive(device), 1,
                       "a finished-but-unjoined thread must still be marked active")

        // Whoever starts the next download joins it first; the flag is what makes that possible.
        XCTAssertEqual(omDownloadJoinBounded(device, 5000), 1)
        XCTAssertEqual(omTestDownloadThreadActive(device), 0)
        XCTAssertEqual(omDownloadJoinBounded(device, 5000), 1, "reaping twice must be a no-op, not a double join")
    }
}

/// `OmStartup()`/`OmShutdown()` end to end, which is the only automated cover over the discovery
/// stop path (M1: `gStartMutex`/`gStartCond` are initialised once and never re-initialised;
/// C17/L1: the bounded stop, and the release of the notify port and the `DeviceData` registry).
///
/// This does start real IOKit matching, so it enumerates whatever is plugged into the machine --
/// but it needs no AX3/AX6 to be attached, and passes either way. A regression in the stop path
/// shows up here as a hang or a non-`OM_OK` return.
final class LibOmapiDiscoveryLifecycleTests: XCTestCase {

    func testRepeatedStartupAndShutdownCyclesComplete() {
        for cycle in 0..<2 {
            XCTAssertEqual(OmStartup(OM_VERSION), 0, "OmStartup failed on cycle \(cycle)")
            XCTAssertEqual(OmShutdown(), 0, "OmShutdown failed on cycle \(cycle)")
        }
        XCTAssertLessThan(OmShutdown(), 0, "a second OmShutdown must report OM_E_NOT_VALID_STATE")
    }
}
