import Foundation

public final class ModelStore: Sendable {
    public static let shared = ModelStore()

    private let hfCacheDir: String
    private let config = OllmlxConfig.shared
    private let logger = OllmlxLogger.shared

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.hfCacheDir = "\(home)/.cache/huggingface/hub"
    }

    // MARK: - Cache Scanning

    /// Check if a model is already downloaded in the HF cache.
    /// Returns true only if the model has at least one .safetensors file (i.e. download is complete).
    public func isModelCached(_ repoID: String) -> Bool {
        let dirName = "models--\(repoID.replacingOccurrences(of: "/", with: "--"))"
        let modelPath = "\(hfCacheDir)/\(dirName)"
        return hasCompleteSafetensors(atModelPath: modelPath)
    }

    /// Scan the HF cache directory and return all locally cached MLX models
    public func refreshCached() -> [LocalModel] {
        let fm = FileManager.default

        guard let entries = try? fm.contentsOfDirectory(atPath: hfCacheDir) else {
            return []
        }

        var models: [LocalModel] = []

        for entry in entries {
            guard entry.hasPrefix("models--mlx-community--") else { continue }

            let parts = entry.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/")
            let repoID = String(parts)

            let modelPath = "\(hfCacheDir)/\(entry)"

            // Only include models with at least one .safetensors file (complete downloads)
            guard hasCompleteSafetensors(atModelPath: modelPath) else { continue }

            // Calculate total disk size across all snapshot files
            let diskSize = directorySize(atPath: modelPath)

            // Get modification date from the model directory
            let modifiedAt: Date
            if let attrs = try? fm.attributesOfItem(atPath: modelPath),
               let date = attrs[.modificationDate] as? Date {
                modifiedAt = date
            } else {
                modifiedAt = Date()
            }

            // Infer quantisation from repo name
            let quantisation = inferQuantisation(from: repoID)

            models.append(LocalModel(
                repoID: repoID,
                diskSize: diskSize,
                modifiedAt: modifiedAt,
                quantisation: quantisation,
                contextLength: nil
            ))
        }

        return models.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // MARK: - Pull

    /// Pull a model using huggingface-cli from the venv. Returns an AsyncThrowingStream of PullProgress.
    /// Uses $VENV/bin/huggingface-cli — never the system PATH version.
    public func pull(model: String) -> AsyncThrowingStream<PullProgress, Error> {
        let venvPath = config.venvPath
        let hfCLIPrimary = "\(venvPath)/bin/huggingface-cli"
        let hfCLIFallback = "\(venvPath)/bin/hf"

        let hfCache = hfCacheDir

        return AsyncThrowingStream { continuation in
            let task = Task.detached { [logger] in
                let fm = FileManager.default
                // Check for huggingface-cli first, then fall back to hf
                let hfCLI: String
                if fm.fileExists(atPath: hfCLIPrimary) {
                    hfCLI = hfCLIPrimary
                } else if fm.fileExists(atPath: hfCLIFallback) {
                    hfCLI = hfCLIFallback
                } else {
                    continuation.finish(throwing: ServerError.modelNotFound(
                        "Neither huggingface-cli nor hf found in \(venvPath)/bin/. Run bootstrap first."
                    ))
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: hfCLI)
                process.arguments = ["download", model]

                let stderrPipe = Pipe()
                process.standardError = stderrPipe
                process.standardOutput = FileHandle.nullDevice

                // Parse stderr for progress output from huggingface-cli
                var lastBytesDownloaded: Int64 = 0
                var lastBytesTotal: Int64? = nil

                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty,
                          let line = String(data: data, encoding: .utf8) else { return }

                    // huggingface-cli outputs progress lines like:
                    // "Downloading model.safetensors: 45%|████      | 1.2G/2.7G [00:30<00:37, 40.5MB/s]"
                    let parsed = Self.parseHFProgress(line: line, model: model)
                    if let progress = parsed {
                        lastBytesDownloaded = progress.bytesDownloaded
                        lastBytesTotal = progress.bytesTotal
                        continuation.yield(progress)
                    }
                }

                // Helper to remove partial download on failure
                let cleanupPartial = {
                    let dirName = "models--\(model.replacingOccurrences(of: "/", with: "--"))"
                    let partialPath = "\(hfCache)/\(dirName)"
                    try? fm.removeItem(atPath: partialPath)
                }

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    cleanupPartial()
                    continuation.finish(throwing: error)
                    return
                }

                stderrPipe.fileHandleForReading.readabilityHandler = nil

                if process.terminationStatus != 0 {
                    cleanupPartial()
                    continuation.finish(throwing: ServerError.modelNotFound(
                        "huggingface-cli download failed with exit code \(process.terminationStatus)"
                    ))
                    return
                }

                logger.info("Model pull complete: \(model)")
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Private Helpers

    /// Check if a model directory contains at least one .safetensors file in its snapshots.
    /// Partial or failed downloads will have the directory structure but no weight files.
    private func hasCompleteSafetensors(atModelPath modelPath: String) -> Bool {
        let fm = FileManager.default
        let snapshotsPath = "\(modelPath)/snapshots"

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: snapshotsPath, isDirectory: &isDir), isDir.boolValue else {
            return false
        }

        let snapshots = (try? fm.contentsOfDirectory(atPath: snapshotsPath)) ?? []
        for snapshot in snapshots {
            let snapshotDir = "\(snapshotsPath)/\(snapshot)"
            let files = (try? fm.contentsOfDirectory(atPath: snapshotDir)) ?? []
            if files.contains(where: { $0.hasSuffix(".safetensors") }) {
                return true
            }
        }
        return false
    }

    private func directorySize(atPath path: String) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }

        var totalSize: Int64 = 0
        while let file = enumerator.nextObject() as? String {
            let filePath = "\(path)/\(file)"
            if let attrs = try? fm.attributesOfItem(atPath: filePath),
               let size = attrs[.size] as? Int64 {
                totalSize += size
            }
        }
        return totalSize
    }

    private func inferQuantisation(from repoID: String) -> String? {
        let lower = repoID.lowercased()
        if lower.contains("4bit") || lower.contains("4-bit") || lower.contains("int4") {
            return "4bit"
        } else if lower.contains("8bit") || lower.contains("8-bit") || lower.contains("int8") {
            return "8bit"
        } else if lower.contains("fp16") || lower.contains("float16") {
            return "fp16"
        } else if lower.contains("bf16") || lower.contains("bfloat16") {
            return "bf16"
        }
        return nil
    }

    /// Parse huggingface-cli progress output into PullProgress
    static func parseHFProgress(line: String, model: String) -> PullProgress? {
        // Match patterns like "45%|████ | 1.2G/2.7G" or "Downloading file: 100%"
        // tqdm output format: "description: XX%|bar| downloaded/total [time<eta, speed]"

        // Look for percentage
        guard let percentRange = line.range(of: #"\d+%"#, options: .regularExpression) else {
            return nil
        }

        let percentStr = String(line[percentRange]).dropLast() // Remove %
        guard let percent = Double(percentStr) else { return nil }

        // Try to parse byte counts (e.g., "1.2G/2.7G" or "500M/1.5G")
        var bytesDownloaded: Int64 = 0
        var bytesTotal: Int64? = nil

        if let sizeRange = line.range(of: #"[\d.]+[KMGT]?B?/[\d.]+[KMGT]?B?"#, options: .regularExpression) {
            let sizeStr = String(line[sizeRange])
            let parts = sizeStr.split(separator: "/")
            if parts.count == 2 {
                bytesDownloaded = Self.parseByteSize(String(parts[0]))
                bytesTotal = Self.parseByteSize(String(parts[1]))
            }
        }

        // If we couldn't parse sizes, estimate from percentage
        if bytesDownloaded == 0 && percent > 0 {
            bytesDownloaded = Int64(percent * 100)
            bytesTotal = 10000
        }

        let description: String
        if let total = bytesTotal {
            description = String(format: "%.1f%% (%@/%@)",
                                 percent,
                                 Self.formatBytes(bytesDownloaded),
                                 Self.formatBytes(total))
        } else {
            description = String(format: "%.1f%%", percent)
        }

        return PullProgress(
            modelID: model,
            bytesDownloaded: bytesDownloaded,
            bytesTotal: bytesTotal,
            description: description
        )
    }

    static func parseByteSize(_ str: String) -> Int64 {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        var numStr = trimmed
        var multiplier: Double = 1

        if trimmed.hasSuffix("T") || trimmed.hasSuffix("TB") {
            multiplier = 1_000_000_000_000
            numStr = String(trimmed.prefix(while: { $0.isNumber || $0 == "." }))
        } else if trimmed.hasSuffix("G") || trimmed.hasSuffix("GB") {
            multiplier = 1_000_000_000
            numStr = String(trimmed.prefix(while: { $0.isNumber || $0 == "." }))
        } else if trimmed.hasSuffix("M") || trimmed.hasSuffix("MB") {
            multiplier = 1_000_000
            numStr = String(trimmed.prefix(while: { $0.isNumber || $0 == "." }))
        } else if trimmed.hasSuffix("K") || trimmed.hasSuffix("KB") {
            multiplier = 1_000
            numStr = String(trimmed.prefix(while: { $0.isNumber || $0 == "." }))
        } else if trimmed.hasSuffix("B") {
            numStr = String(trimmed.dropLast())
        }

        guard let value = Double(numStr) else { return 0 }
        return Int64(value * multiplier)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 {
            return String(format: "%.1f MB", mb)
        }
        let kb = Double(bytes) / 1_000
        return String(format: "%.1f KB", kb)
    }
}
