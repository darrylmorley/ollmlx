import Combine
import Foundation
import OSLog

@MainActor
public final class ServerManager: ObservableObject {
    public static let shared = ServerManager()

    @Published public private(set) var state: ServerState = .stopped

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private let config = OllmlxConfig.shared
    private let logger = OllmlxLogger.shared
    private let modelStore = ModelStore.shared

    private static let startupTimeout: TimeInterval = 120 // seconds
    private static let pollInterval: TimeInterval = 0.5
    private static let sigintGracePeriod: TimeInterval = 5

    private init() {}

    // MARK: - Start

    public func start(model: String) async throws {
        guard case .stopped = state else {
            throw ServerError.alreadyRunning
        }

        // Validate model is cached locally
        guard modelStore.isModelCached(model) else {
            throw ServerError.modelNotFound(model)
        }

        state = .starting(model: model)
        logger.info("Starting mlx_lm.server with model: \(model)")

        let pythonPath = config.pythonPath
        guard !pythonPath.isEmpty else {
            state = .error("Python path not configured. Run bootstrap first.")
            throw ServerError.modelNotFound("Python path not configured")
        }

        // Allocate ephemeral port for mlx_lm.server
        let internalPort: Int
        do {
            internalPort = try allocateEphemeralPort()
        } catch {
            state = .error("Failed to allocate ephemeral port: \(error)")
            throw error
        }

        logger.info("Allocated ephemeral port: \(internalPort)")

        // Spawn mlx_lm.server process
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [
            "-m", "mlx_lm.server",
            "--model", model,
            "--port", String(internalPort),
            "--max-tokens", String(config.maxTokens),
        ]

        // Pipe stdout/stderr to log file
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.logger.writeProcessOutput(data)
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.logger.writeProcessOutput(data)
        }

        self.process = proc
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        do {
            try proc.run()
        } catch {
            state = .error("Failed to launch mlx_lm.server: \(error.localizedDescription)")
            cleanup()
            throw error
        }

        logger.info("mlx_lm.server launched with PID \(proc.processIdentifier)")

        // Wait for server to become ready
        do {
            try await waitForServer(port: internalPort, process: proc)
        } catch {
            // If wait failed, kill the process
            await stopProcess()
            throw error
        }

        // Point the proxy at the new upstream
        await ProxyServer.shared.setUpstream(port: internalPort)

        state = .running(model: model, port: internalPort)
        config.lastActiveModel = model
        logger.info("mlx_lm.server is ready on port \(internalPort)")
    }

    // MARK: - Stop

    public func stop() async {
        guard case .running = state else {
            // Also handle stopping from .starting or .error states if process exists
            if process != nil {
                await stopProcess()
            }
            state = .stopped
            return
        }

        state = .stopping
        logger.info("Stopping mlx_lm.server")

        // Clear proxy upstream immediately — new requests get 503 during shutdown
        await ProxyServer.shared.clearUpstream()
        await stopProcess()
        state = .stopped
        logger.info("mlx_lm.server stopped")
    }

    // MARK: - Wait for Server

    /// Polls /v1/models on the given port until the server responds or the process dies.
    /// Fast-fails immediately if the process exits during polling.
    private func waitForServer(port: Int, process: Process) async throws {
        let startTime = Date()
        let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!

        while Date().timeIntervalSince(startTime) < Self.startupTimeout {
            // Fast-fail: check if process died
            guard process.isRunning else {
                state = .error("mlx_lm.server exited during startup (code \(process.terminationStatus))")
                throw ServerError.processDied
            }

            // Try to reach the server
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode == 200 {
                    return // Server is ready
                }
            } catch {
                // Connection refused / not ready yet — keep polling
            }

            try await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
        }

        // Timed out
        state = .error("Timed out waiting for mlx_lm.server after \(Int(Self.startupTimeout))s")
        throw ServerError.timeout
    }

    // MARK: - Process Management

    /// Sends SIGINT, waits 5 seconds, falls back to SIGKILL
    private func stopProcess() async {
        guard let proc = process, proc.isRunning else {
            cleanup()
            return
        }

        // Send SIGINT first
        logger.info("Sending SIGINT to PID \(proc.processIdentifier)")
        proc.interrupt() // Sends SIGINT

        // Wait up to 5 seconds for graceful shutdown
        let deadline = Date().addingTimeInterval(Self.sigintGracePeriod)
        while proc.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        // If still running, send SIGKILL
        if proc.isRunning {
            logger.info("SIGINT timed out, sending SIGKILL to PID \(proc.processIdentifier)")
            kill(proc.processIdentifier, SIGKILL)
            proc.waitUntilExit()
        }

        logger.info("Process terminated with status \(proc.terminationStatus)")
        cleanup()
    }

    private func cleanup() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
    }

    // MARK: - Ephemeral Port Allocation

    /// Binds to port 0, reads the OS-assigned port, then closes the socket.
    public func allocateEphemeralPort() throws -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw NSError(domain: "ollmlx", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create socket"])
        }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // Let OS assign
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw NSError(domain: "ollmlx", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to bind to port 0"])
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(sock, sockPtr, &addrLen)
            }
        }
        guard nameResult == 0 else {
            throw NSError(domain: "ollmlx", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to get assigned port"])
        }

        let port = Int(UInt16(bigEndian: boundAddr.sin_port))
        return port
    }
}
