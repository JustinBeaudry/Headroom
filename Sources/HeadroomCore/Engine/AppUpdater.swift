import Foundation
import CryptoKit

public enum AppUpdateError: Error, LocalizedError, Sendable {
    case missingZipAsset
    case notInstalledAsAppBundle
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case signatureInvalid(String)
    case teamIdentifierMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .missingZipAsset:
            return "This release does not contain a macOS .zip app bundle."
        case .notInstalledAsAppBundle:
            return "In-app auto-install is only available when running from Headroom.app."
        case .downloadFailed(let msg):
            return "Download failed: \(msg)"
        case .checksumMismatch(let expected, let actual):
            return "SHA-256 verification failed (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)."
        case .extractionFailed(let msg):
            return "Failed to unpack update archive: \(msg)"
        case .signatureInvalid(let msg):
            return "Code signature verification failed: \(msg)"
        case .teamIdentifierMismatch(let expected, let actual):
            return "Signing Team ID mismatch (expected \(expected), got \(actual))."
        }
    }
}

public enum AppUpdateProgress: Sendable, Equatable {
    case idle
    case downloading
    case verifying
    case installing
    case failed(String)
}

/// Downloads, SHA-256 checks, codesign-verifies, and atomically installs a new Headroom.app release.
public final class AppUpdater: Sendable {
    private let httpClient: any HTTPClient

    public init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    public func downloadVerifyAndInstall(
        release: ReleaseInfo,
        onProgress: @escaping @Sendable (AppUpdateProgress) -> Void
    ) async throws {
        guard let zipURL = release.zipAssetURL, let zipName = release.zipAssetName else {
            throw AppUpdateError.missingZipAsset
        }
        let currentBundleURL = Bundle.main.bundleURL
        guard currentBundleURL.pathExtension == "app" else {
            throw AppUpdateError.notInstalledAsAppBundle
        }

        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        // 1. Download release archive
        onProgress(.downloading)
        let zipResp = try await httpClient.send(HTTPRequest(url: zipURL, timeoutInterval: 120))
        guard zipResp.isSuccess else {
            throw AppUpdateError.downloadFailed("HTTP \(zipResp.statusCode)")
        }
        let localZip = stagingDir.appendingPathComponent(zipName)
        try zipResp.body.write(to: localZip, options: .atomic)

        // 2. Verify SHA-256 against SHA256SUMS.txt when available
        onProgress(.verifying)
        if let sumsURL = release.checksumsURL {
            let sumsResp = try await httpClient.send(HTTPRequest(url: sumsURL, timeoutInterval: 20))
            if sumsResp.isSuccess, let sumsText = String(data: sumsResp.body, encoding: .utf8) {
                let table = UpdateChecker.parseChecksums(sumsText)
                if let expected = table[zipName] {
                    let digest = SHA256.hash(data: zipResp.body)
                    let actual = digest.map { String(format: "%02x", $0) }.joined()
                    if actual != expected {
                        throw AppUpdateError.checksumMismatch(expected: expected, actual: actual)
                    }
                }
            }
        }

        // 3. Extract Headroom.app using macOS ditto (preserves resource forks & code signatures)
        let unpackDir = stagingDir.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpackDir, withIntermediateDirectories: true)
        let dittoResult = runProcess("/usr/bin/ditto", arguments: ["-x", "-k", localZip.path, unpackDir.path])
        guard dittoResult.exitCode == 0 else {
            throw AppUpdateError.extractionFailed(dittoResult.stderr)
        }

        let newAppURL = unpackDir.appendingPathComponent("Headroom.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: newAppURL.path) else {
            throw AppUpdateError.extractionFailed("Headroom.app not found inside archive.")
        }

        // 4. Verify strict macOS code signature + Team ID continuity
        let verifyResult = runProcess("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", newAppURL.path])
        guard verifyResult.exitCode == 0 else {
            throw AppUpdateError.signatureInvalid(verifyResult.stderr)
        }

        if let currentTeam = extractTeamIdentifier(for: currentBundleURL),
           let newTeam = extractTeamIdentifier(for: newAppURL),
           currentTeam != newTeam {
            throw AppUpdateError.teamIdentifierMismatch(expected: currentTeam, actual: newTeam)
        }

        // 5. Handoff replacement & relaunch after current PID exits
        onProgress(.installing)
        let pid = ProcessInfo.processInfo.processIdentifier
        let scriptPath = stagingDir.appendingPathComponent("install-and-relaunch.sh")
        let targetPath = currentBundleURL.path
        let stagedPath = newAppURL.path

        let script = """
        #!/usr/bin/env bash
        set -euo pipefail
        TARGET=\(shellQuote(targetPath))
        STAGED=\(shellQuote(stagedPath))
        STAGING_ROOT=\(shellQuote(stagingDir.path))
        PID=\(pid)

        for _ in $(seq 1 40); do
            if ! kill -0 "$PID" 2>/dev/null; then break; fi
            sleep 0.2
        done

        BACKUP="${TARGET}.old.$$"
        mv "$TARGET" "$BACKUP"
        if mv "$STAGED" "$TARGET"; then
            rm -rf "$BACKUP" "$STAGING_ROOT"
            open -n "$TARGET"
        else
            mv "$BACKUP" "$TARGET"
            exit 1
        fi
        """
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptPath.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
    }

    private func extractTeamIdentifier(for appURL: URL) -> String? {
        let info = runProcess("/usr/bin/codesign", arguments: ["-dv", appURL.path])
        let combined = info.stdout + "\n" + info.stderr
        for line in combined.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("TeamIdentifier=") {
                let value = line.replacingOccurrences(of: "TeamIdentifier=", with: "").trimmingCharacters(in: .whitespaces)
                return value == "not set" ? nil : value
            }
        }
        return nil
    }

    private func runProcess(_ path: String, arguments: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (process.terminationStatus, out, err)
        } catch {
            return (-1, "", error.localizedDescription)
        }
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
