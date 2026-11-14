import Foundation
import Darwin

struct DaemonConfiguration {
    let executable: URL
    var arguments = ["serve"]
    let environment: [String: String]
    let logURL: URL
    var timeout: TimeInterval = 10
    var pollInterval: TimeInterval = 0.15
    var stopGracePeriod: TimeInterval = 1

    static func bundled() -> Self {
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ymd")
        return Self(executable: contents.appendingPathComponent("Helpers/ymd"), environment: bundleEnvironment(contents: contents, runDirectory: support.appendingPathComponent("run"), version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"), logURL: support.appendingPathComponent("logs/bundled-daemon.log"))
    }

    static func bundleEnvironment(contents: URL, runDirectory: URL, version: String, inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = inherited.filter { key, _ in
            !["DYLD_", "GST_", "GIO_"].contains(where: key.hasPrefix)
        }
        let plugins = contents.appendingPathComponent("Resources/gstreamer-1.0").path
        let scanner = contents.appendingPathComponent("Helpers/gst-plugin-scanner").path
        let registry = runDirectory.appendingPathComponent("gst-registry-\(version).bin").path
        for suffix in ["", "_1_0"] {
            env["GST_PLUGIN_SYSTEM_PATH\(suffix)"] = plugins
            env["GST_PLUGIN_PATH\(suffix)"] = plugins
            env["GST_PLUGIN_SCANNER\(suffix)"] = scanner
            env["GST_REGISTRY\(suffix)"] = registry
        }
        env["GIO_MODULE_DIR"] = contents.appendingPathComponent("Resources/gio/modules").path
        env["GIO_EXTRA_MODULES"] = env["GIO_MODULE_DIR"]
        env["DYLD_LIBRARY_PATH"] = contents.appendingPathComponent("Frameworks").path
        env["DYLD_FALLBACK_LIBRARY_PATH"] = env["DYLD_LIBRARY_PATH"]
        env["SSL_CERT_FILE"] = contents.appendingPathComponent("Resources/certs/ca-certificates.crt").path
        env["YMD_CA_BUNDLE"] = env["SSL_CERT_FILE"]
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }
}

enum DaemonProbe { case absent, available, conflict }

@MainActor
final class DaemonSupervisor {
    enum Phase: Equatable { case stopped, starting, ready, failed(String) }
    private(set) var phase: Phase = .stopped { didSet { onChange?(phase) } }
    var onChange: ((Phase) -> Void)?
    var ownedProcessID: Int32? { process?.processIdentifier }
    private let configuration: DaemonConfiguration
    private let probe: () async -> DaemonProbe
    private var process: Process?
    private var output: FileHandle?
    private var generation = UUID()
    private var stopping = false
    private var killTask: Task<Void, Never>?

    init(configuration: DaemonConfiguration = .bundled(), probe: @escaping () async -> DaemonProbe) {
        self.configuration = configuration
        self.probe = probe
    }

    func start() async {
        guard phase != .starting, phase != .ready else { return }
        phase = .starting
        let attempt = UUID()
        generation = attempt
        guard await waitForOwnedExit(attempt: attempt) else { return }
        let initial = await probe()
        guard generation == attempt else { return }
        switch initial {
        case .available: phase = .ready; return
        case .conflict: phase = .failed("Порт 8765 занят или ключ сессии недействителен. Проверьте другой экземпляр ymd."); return
        case .absent: break
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: configuration.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let registry = configuration.environment["GST_REGISTRY_1_0"] {
                try fm.createDirectory(at: URL(fileURLWithPath: registry).deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            if !fm.fileExists(atPath: configuration.logURL.path) {
                fm.createFile(atPath: configuration.logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let log = try FileHandle(forWritingTo: configuration.logURL)
            try log.seekToEnd()
            output = log
            let child = Process()
            child.executableURL = configuration.executable
            child.arguments = configuration.arguments
            child.environment = configuration.environment
            child.standardOutput = log
            child.standardError = log
            child.terminationHandler = { [weak self] child in
                Task { @MainActor in
                    guard let self, self.process === child else { return }
                    let unexpected = !self.stopping && self.generation == attempt
                    self.release(child)
                    if unexpected {
                        self.phase = .failed("Демон завершился (код \(child.terminationStatus)). Повторите запуск. Лог: \(self.configuration.logURL.path)")
                    }
                }
            }
            process = child
            try child.run()
            let deadline = Date().addingTimeInterval(configuration.timeout)
            while Date() < deadline {
                guard generation == attempt, phase == .starting else { return }
                guard child.isRunning else { await fail("Демон завершился при запуске (код \(child.terminationStatus))."); return }
                let result = await probe()
                guard generation == attempt, phase == .starting else { return }
                if result == .available { phase = .ready; return }
                try await Task.sleep(nanoseconds: UInt64(configuration.pollInterval * 1_000_000_000))
            }
            await fail("Демон не запустился за \(Int(configuration.timeout)) с. Лог: \(configuration.logURL.path)")
        } catch {
            await fail("Не удалось запустить встроенный демон: \(error.localizedDescription)")
        }
    }

    func connectionLost() {
        guard phase == .ready else { return }
        // Краткая ошибка HTTP не лишает клиента владения работающим ребёнком.
        guard process?.isRunning != true else { return }
        phase = .failed("Соединение с музыкальным сервисом потеряно. Повторите подключение.")
    }

    private func fail(_ message: String) async {
        stop()
        phase = .failed(message)
        _ = await waitForOwnedExit(attempt: generation)
    }

    private func release(_ child: Process) {
        guard process === child else { return }
        process = nil
        stopping = false
        killTask?.cancel()
        killTask = nil
        try? output?.close()
        output = nil
    }

    private func waitForOwnedExit(attempt: UUID) async -> Bool {
        let deadline = Date().addingTimeInterval(configuration.stopGracePeriod + 1)
        while let child = process {
            guard generation == attempt else { return false }
            if !child.isRunning {
                release(child)
                break
            }
            if Date() >= deadline {
                phase = .failed("Собственный демон ещё завершается. Повторите подключение позже.")
                return false
            }
            do { try await Task.sleep(nanoseconds: 20_000_000) }
            catch { return false }
        }
        return generation == attempt
    }

    func stop() {
        generation = UUID()
        phase = .stopped
        guard let child = process else { return }
        guard child.isRunning else { release(child); return }
        guard !stopping else { return }
        stopping = true
        child.terminate()
        // Владение сохраняется до terminationHandler; SIGKILL касается только этого ребёнка.
        killTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64((self?.configuration.stopGracePeriod ?? 1) * 1_000_000_000)) }
            catch { return }
            guard let self, self.process === child, self.stopping, child.isRunning else { return }
            Darwin.kill(child.processIdentifier, SIGKILL)
        }
    }
}
