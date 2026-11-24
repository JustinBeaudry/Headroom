import Foundation

public enum HeadroomPaths {
    public static var appSupportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["HEADROOM_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Headroom", isDirectory: true)
    }

    public static var stateFileURL: URL {
        appSupportDirectory.appendingPathComponent("state.json", isDirectory: false)
    }

    public static var configFileURL: URL {
        appSupportDirectory.appendingPathComponent("config.json", isDirectory: false)
    }

    public static var alertStateFileURL: URL {
        appSupportDirectory.appendingPathComponent("alerts.json", isDirectory: false)
    }

    public static var agyStatusFileURL: URL {
        appSupportDirectory.appendingPathComponent("agy-status.json", isDirectory: false)
    }
}

public actor StateStore {
    private let fileURL: URL

    public init(fileURL: URL = HeadroomPaths.stateFileURL) {
        self.fileURL = fileURL
    }

    public func load() -> HeadroomState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try HeadroomJSON.makeDecoder().decode(HeadroomState.self, from: data)
        } catch {
            return nil
        }
    }

    public func save(_ state: HeadroomState) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try HeadroomJSON.makeEncoder(prettyPrinted: true).encode(state)
        let tempURL = dir.appendingPathComponent(".state-\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: [.atomic])
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: fileURL)
        }
    }
}
