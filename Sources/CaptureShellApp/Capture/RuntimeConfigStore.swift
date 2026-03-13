import Foundation

enum RuntimeConfigStoreError: Error, LocalizedError {
    case missingFile(URL)
    case unreadablePath(URL)

    var errorDescription: String? {
        switch self {
        case let .missingFile(url):
            return "No saved runtime config found at \(url.path)."
        case let .unreadablePath(url):
            return "Cannot read runtime config path at \(url.path)."
        }
    }
}

struct RuntimeConfigStore {
    let configURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default, appFolderName: String? = Bundle.main.bundleIdentifier) {
        self.fileManager = fileManager

        let appSupportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)

        let folderName = appFolderName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? appFolderName!
            : "CaptureShellApp"

        let configDirectory = appSupportRoot.appendingPathComponent(folderName, isDirectory: true)
        self.configURL = configDirectory.appendingPathComponent("runtime-config.json", isDirectory: false)
    }

    func save(_ config: CaptureRuntimeConfig) throws {
        let directory = configURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(config)
        try data.write(to: configURL, options: .atomic)
    }

    func load() throws -> CaptureRuntimeConfig {
        guard fileManager.fileExists(atPath: configURL.path) else {
            throw RuntimeConfigStoreError.missingFile(configURL)
        }

        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            throw RuntimeConfigStoreError.unreadablePath(configURL)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(CaptureRuntimeConfig.self, from: data)
    }
}
