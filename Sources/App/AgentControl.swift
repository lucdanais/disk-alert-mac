import Foundation

/// Installs, starts and stops the background agent through launchd.
/// The agent lives inside the app bundle, so it always matches the installed app.
enum AgentControl {
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(DiskAlert.agentLabel).plist")
    }

    static var executableURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/Disk Alert Agent.app/Contents/MacOS/DiskAlertAgent")
    }

    private static var domain: String { "gui/\(getuid())" }

    private static var plistContents: [String: Any] {
        [
            "Label": DiskAlert.agentLabel,
            "ProgramArguments": [executableURL.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Background"
        ]
    }

    /// Makes sure the agent is installed, points at this copy of the app, and is running.
    static func enable() {
        removeLegacyAgents()
        let wanted = plistContents as NSDictionary
        let current = NSDictionary(contentsOf: plistURL)
        let needsWrite = current == nil || current != wanted
        if needsWrite {
            try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            wanted.write(to: plistURL, atomically: true)
            launchctl(["bootout", "\(domain)/\(DiskAlert.agentLabel)"])
        }
        if needsWrite || !isRunning {
            launchctl(["bootstrap", domain, plistURL.path])
        }
    }

    /// Stops the agent and removes it from login.
    static func disable() {
        removeLegacyAgents()
        launchctl(["bootout", "\(domain)/\(DiskAlert.agentLabel)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    /// Finds agents left behind by older versions under a different label, then stops and removes them.
    /// Any plist in ~/Library/LaunchAgents that runs the Disk Alert Agent binary counts, whatever its label.
    static func removeLegacyAgents() {
        let agentSuffix = "/Disk Alert Agent.app/Contents/MacOS/DiskAlertAgent"
        let folder = plistURL.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "plist" {
            guard file.standardizedFileURL != plistURL.standardizedFileURL,
                  let dict = NSDictionary(contentsOf: file),
                  let args = dict["ProgramArguments"] as? [String],
                  let last = args.last, last.hasSuffix(agentSuffix) else { continue }
            if let label = dict["Label"] as? String, label != DiskAlert.agentLabel {
                launchctl(["bootout", "\(domain)/\(label)"])
            }
            try? FileManager.default.removeItem(at: file)
        }
    }

    static var isRunning: Bool {
        launchctl(["print", "\(domain)/\(DiskAlert.agentLabel)"]) == 0
    }

    /// Asks the agent binary to post one test notification.
    static func sendTest() {
        let p = Process()
        p.executableURL = executableURL
        p.arguments = ["--test"]
        try? p.run()
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
