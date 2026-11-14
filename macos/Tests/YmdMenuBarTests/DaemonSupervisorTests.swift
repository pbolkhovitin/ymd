import XCTest
@testable import ymd_menubar

@MainActor
final class DaemonSupervisorTests: XCTestCase {
    private func configuration(_ script: String) throws -> DaemonConfiguration {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("child.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        return DaemonConfiguration(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [file.path], environment: [:], logURL: dir.appendingPathComponent("log"), timeout: 0.3, pollInterval: 0.02)
    }

    func testOwnProcessStartsOnceAndStops() async throws {
        let config = try configuration("exec /bin/sleep 20")
        var probes = 0
        let supervisor = DaemonSupervisor(configuration: config) {
            probes += 1
            return probes == 1 ? .absent : .available
        }
        await supervisor.start()
        let pid = try XCTUnwrap(supervisor.ownedProcessID)
        await supervisor.start()
        XCTAssertEqual(supervisor.ownedProcessID, pid)
        XCTAssertEqual(supervisor.phase, .ready)
        supervisor.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(kill(pid, 0), -1)
    }

    func testExternalProcessIsNotOwnedOrStopped() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["20"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let supervisor = DaemonSupervisor(configuration: try configuration("exit 99")) { .available }
        await supervisor.start()
        XCTAssertEqual(supervisor.phase, .ready)
        XCTAssertNil(supervisor.ownedProcessID)
        supervisor.stop()
        XCTAssertTrue(child.isRunning)
    }

    func testStartupCrashFailsEarlyAndCanRetry() async throws {
        let supervisor = DaemonSupervisor(configuration: try configuration("exit 7")) { .absent }
        await supervisor.start()
        guard case .failed = supervisor.phase else { return XCTFail("Падение должно отображаться как ошибка") }
        XCTAssertNil(supervisor.ownedProcessID)
        await supervisor.start()
        guard case .failed = supervisor.phase else { return XCTFail("Повторный запуск должен завершиться ошибкой скрипта") }
    }

    func testTimeoutTerminatesOnlyOwnedChild() async throws {
        let supervisor = DaemonSupervisor(configuration: try configuration("exec /bin/sleep 20")) { .absent }
        await supervisor.start()
        guard case .failed = supervisor.phase else { return XCTFail("Ожидается таймаут") }
        XCTAssertNil(supervisor.ownedProcessID)
    }

    func testConflictDoesNotLaunchChild() async throws {
        let supervisor = DaemonSupervisor(configuration: try configuration("exit 99")) { .conflict }
        await supervisor.start()
        guard case .failed = supervisor.phase else { return XCTFail("Чужой сервис должен блокировать запуск") }
        XCTAssertNil(supervisor.ownedProcessID)
    }

    func testRuntimeCrashReportsFailure() async throws {
        var probes = 0
        let supervisor = DaemonSupervisor(configuration: try configuration("/bin/sleep 0.15; exit 7")) {
            probes += 1
            return probes == 1 ? .absent : .available
        }
        await supervisor.start()
        XCTAssertEqual(supervisor.phase, .ready)
        try await Task.sleep(nanoseconds: 400_000_000)
        guard case .failed = supervisor.phase else { return XCTFail("Падение после готовности должно отображаться") }
    }

    func testBundleEnvironmentRemovesInheritedRuntimePaths() {
        let contents = URL(fileURLWithPath: "/tmp/App.app/Contents")
        let result = DaemonConfiguration.bundleEnvironment(contents: contents, runDirectory: URL(fileURLWithPath: "/tmp/run"), version: "test", inherited: ["GST_DEBUG": "9", "GIO_USE_TLS": "bad", "DYLD_INSERT_LIBRARIES": "bad", "HOME": "/tmp/home"])
        XCTAssertNil(result["GST_DEBUG"])
        XCTAssertNil(result["GIO_USE_TLS"])
        XCTAssertNil(result["DYLD_INSERT_LIBRARIES"])
        XCTAssertEqual(result["YMD_CA_BUNDLE"], "/tmp/App.app/Contents/Resources/certs/ca-certificates.crt")
        XCTAssertEqual(result["GST_PLUGIN_PATH_1_0"], "/tmp/App.app/Contents/Resources/gstreamer-1.0")
        XCTAssertEqual(result["DYLD_LIBRARY_PATH"], "/tmp/App.app/Contents/Frameworks")
        XCTAssertEqual(result["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
    }
}
