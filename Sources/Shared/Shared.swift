import Foundation

// MARK: - Identifiers and paths

enum DiskAlert {
    static let appName = "Disk Alert"
    static let agentLabel = "app.diskalert.agent"

    static var supportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent(appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static var settingsURL: URL { supportFolder.appendingPathComponent("settings.json") }
    static var drivesURL: URL { supportFolder.appendingPathComponent("drives.json") }
    static var historyURL: URL { supportFolder.appendingPathComponent("history.json") }
}

// MARK: - Settings

struct DriveRule: Codable, Equatable {
    var split = false
    var sound = "Default"
    var connectSound = "Default"
    var ejectSound = "Default"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        split = try c.decodeIfPresent(Bool.self, forKey: .split) ?? false
        sound = try c.decodeIfPresent(String.self, forKey: .sound) ?? "Default"
        connectSound = try c.decodeIfPresent(String.self, forKey: .connectSound) ?? "Default"
        ejectSound = try c.decodeIfPresent(String.self, forKey: .ejectSound) ?? "Default"
    }
}

struct AppSettings: Codable, Equatable {
    var enabled = true
    var connectSound = "Glass"
    var ejectSound = "Pop"
    var unsafeSound = "Basso"        // "Off" plays no sound
    var connectTitle = "Drive Connected"
    var ejectTitle = "Drive Ejected"
    var unsafeTitle = "Not Ejected Properly"
    var showInfo = true
    var openInFinder = false
    var diskImageSound = "Default"   // "Default", "Mute" or a sound name
    var playSoundDirectly = false    // fallback if notification sounds stay silent
    var driveRules: [String: DriveRule] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let d = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        connectSound = try c.decodeIfPresent(String.self, forKey: .connectSound) ?? d.connectSound
        ejectSound = try c.decodeIfPresent(String.self, forKey: .ejectSound) ?? d.ejectSound
        unsafeSound = try c.decodeIfPresent(String.self, forKey: .unsafeSound) ?? d.unsafeSound
        connectTitle = try c.decodeIfPresent(String.self, forKey: .connectTitle) ?? d.connectTitle
        ejectTitle = try c.decodeIfPresent(String.self, forKey: .ejectTitle) ?? d.ejectTitle
        unsafeTitle = try c.decodeIfPresent(String.self, forKey: .unsafeTitle) ?? d.unsafeTitle
        showInfo = try c.decodeIfPresent(Bool.self, forKey: .showInfo) ?? d.showInfo
        openInFinder = try c.decodeIfPresent(Bool.self, forKey: .openInFinder) ?? d.openInFinder
        diskImageSound = try c.decodeIfPresent(String.self, forKey: .diskImageSound) ?? d.diskImageSound
        playSoundDirectly = try c.decodeIfPresent(Bool.self, forKey: .playSoundDirectly) ?? d.playSoundDirectly
        driveRules = try c.decodeIfPresent([String: DriveRule].self, forKey: .driveRules) ?? [:]
    }
}

struct KnownDrive: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var format: String
    var capacity: Int64
    var lastSeen: Date
}

struct HistoryEvent: Codable, Equatable {
    enum Kind: String, Codable { case connected, ejected, unsafe }
    var date: Date
    var name: String
    var kind: Kind
}

// MARK: - Storage

enum Store {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static var settings: AppSettings {
        load(AppSettings.self, from: DiskAlert.settingsURL) ?? AppSettings()
    }

    static var drives: [String: KnownDrive] {
        load([String: KnownDrive].self, from: DiskAlert.drivesURL) ?? [:]
    }

    static var history: [HistoryEvent] {
        load([HistoryEvent].self, from: DiskAlert.historyURL) ?? []
    }

    static func remember(_ drive: KnownDrive) {
        var all = drives
        all[drive.id] = drive
        save(all, to: DiskAlert.drivesURL)
    }

    static func log(_ event: HistoryEvent) {
        var all = history
        all.insert(event, at: 0)
        if all.count > 100 { all = Array(all.prefix(100)) }
        save(all, to: DiskAlert.historyURL)
    }
}

// MARK: - Sounds

enum Sounds {
    static let builtIn = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
                          "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
    static let extensions = ["aiff", "aif", "caf", "wav"]

    static var userFolder: URL {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static var searchFolders: [URL] {
        [userFolder, URL(fileURLWithPath: "/Library/Sounds"), URL(fileURLWithPath: "/System/Library/Sounds")]
    }

    /// Sound files the user added, in ~/Library/Sounds.
    static var custom: [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: userFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    static var customNames: [String] {
        custom.map { $0.deletingPathExtension().lastPathComponent }.filter { !builtIn.contains($0) }
    }

    static var allNames: [String] { builtIn + customNames }

    static func url(for name: String) -> URL? {
        for folder in searchFolders {
            for ext in extensions {
                let url = folder.appendingPathComponent("\(name).\(ext)")
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }
}

// MARK: - Formatting

enum Format {
    static func bytes(_ value: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: value)
    }
}
