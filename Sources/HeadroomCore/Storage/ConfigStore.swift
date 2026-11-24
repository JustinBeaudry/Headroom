import Foundation

public actor ConfigStore {
    private let fileURL: URL

    public init(fileURL: URL = HeadroomPaths.configFileURL) {
        self.fileURL = fileURL
    }

    public func load() -> HeadroomConfig {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return HeadroomConfig()
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try HeadroomJSON.makeDecoder().decode(HeadroomConfig.self, from: data)
        } catch {
            return HeadroomConfig()
        }
    }

    public func save(_ config: HeadroomConfig) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try HeadroomJSON.makeEncoder(prettyPrinted: true).encode(config)
        try data.write(to: fileURL, options: [.atomic])
    }

    public func exists() -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    public nonisolated var path: String {
        fileURL.path
    }
}
