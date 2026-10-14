import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct MountedVolume: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let name: String
    let free: Int64
    let total: Int64
}

final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            Store.save(settings, to: DiskAlert.settingsURL)
            if settings.enabled != oldValue.enabled {
                settings.enabled ? AgentControl.enable() : AgentControl.disable()
            }
        }
    }
    @Published var drives: [KnownDrive] = []
    @Published var mountedVolumes: [MountedVolume] = []
    @Published var customSounds: [String] = []
    @Published var launchAtLogin = false

    private var player: NSSound?

    init() {
        settings = Store.settings
        if !FileManager.default.fileExists(atPath: DiskAlert.settingsURL.path) {
            Store.save(settings, to: DiskAlert.settingsURL)
        }
        if settings.enabled { AgentControl.enable() }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refresh()

        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Give the agent a moment to record the drive first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.refresh() }
            }
        }
    }

    func refresh() {
        drives = Store.drives.values.sorted { $0.lastSeen > $1.lastSeen }
        customSounds = Sounds.customNames
        mountedVolumes = Self.currentVolumes()
    }

    static func currentVolumes() -> [MountedVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsEjectableKey,
                                      .volumeIsRemovableKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard url.path.hasPrefix("/Volumes/"), let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let external = v.volumeIsInternal == false || v.volumeIsEjectable == true || v.volumeIsRemovable == true
            guard external else { return nil }
            return MountedVolume(url: url, name: v.volumeName ?? url.lastPathComponent,
                                 free: Int64(v.volumeAvailableCapacity ?? 0), total: Int64(v.volumeTotalCapacity ?? 0))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Per-drive rules

    func rule(for id: String) -> DriveRule { settings.driveRules[id] ?? DriveRule() }

    func setRule(_ rule: DriveRule, for id: String) { settings.driveRules[id] = rule }

    func ruleBinding(for id: String) -> Binding<DriveRule> {
        Binding(get: { self.rule(for: id) }, set: { self.setRule($0, for: id) })
    }

    // MARK: Sounds

    func preview(_ name: String) {
        guard let url = Sounds.url(for: name) else { return }
        player?.stop()
        player = NSSound(contentsOf: url, byReference: true)
        player?.play()
    }

    /// Converts any audio file macOS can read into a notification-ready .caf in ~/Library/Sounds.
    func addSound(from source: URL) {
        let base = source.deletingPathExtension().lastPathComponent
        var name = base
        var n = 2
        while Sounds.url(for: name) != nil { name = "\(base) \(n)"; n += 1 }
        let dest = Sounds.userFolder.appendingPathComponent("\(name).caf")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "caff", "-d", "LEI16", source.path, dest.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        var ok = false
        if (try? p.run()) != nil {
            p.waitUntilExit()
            ok = p.terminationStatus == 0
        }
        if !ok, Sounds.extensions.contains(source.pathExtension.lowercased()) {
            let copy = Sounds.userFolder.appendingPathComponent("\(name).\(source.pathExtension.lowercased())")
            try? FileManager.default.copyItem(at: source, to: copy)
        }
        refresh()
    }

    func chooseSounds() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.message = "Choose sounds to add to Disk Alert"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { panel.urls.forEach(addSound) }
    }

    func removeSound(_ name: String) {
        guard let url = Sounds.url(for: name), url.path.hasPrefix(Sounds.userFolder.path) else { return }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        refresh()
    }

    func showSoundsFolder() {
        NSWorkspace.shared.open(Sounds.userFolder)
    }

    // MARK: Startup

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            if on { SMAppService.openSystemSettingsLoginItems() }
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Ejecting

    func eject(_ volume: MountedVolume) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Couldn’t eject “\(volume.name)”"
            alert.informativeText = "Something may still be using it. Close any open files from the drive and try again."
            alert.runModal()
        }
        refresh()
    }

    /// Two confirmations, with the final button locked for three seconds.
    func ejectAll() {
        let volumes = Self.currentVolumes()
        guard !volumes.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)

        let first = NSAlert()
        first.messageText = "Eject all drives?"
        first.informativeText = "These will be ejected:\n" + volumes.map { "• \($0.name)" }.joined(separator: "\n")
        first.addButton(withTitle: "Cancel")
        first.addButton(withTitle: "Continue")
        guard first.runModal() == .alertSecondButtonReturn else { return }

        let second = NSAlert()
        second.alertStyle = .warning
        second.messageText = "Are you sure?"
        second.informativeText = "Anything still copying to these drives will stop. Close any open files first."
        second.addButton(withTitle: "Cancel")
        let eject = second.addButton(withTitle: "Eject All (3)")
        eject.isEnabled = false
        var count = 3
        let timer = Timer(timeInterval: 1, repeats: true) { t in
            count -= 1
            if count <= 0 {
                eject.title = "Eject All"
                eject.isEnabled = true
                t.invalidate()
            } else {
                eject.title = "Eject All (\(count))"
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        let result = second.runModal()
        timer.invalidate()
        guard result == .alertSecondButtonReturn else { return }

        var failed: [String] = []
        for v in volumes {
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: v.url) } catch { failed.append(v.name) }
        }
        if !failed.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Some drives couldn’t be ejected"
            alert.informativeText = failed.joined(separator: ", ") + " may still be in use."
            alert.runModal()
        }
        refresh()
    }

    // MARK: Uninstall

    func uninstall() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall Disk Alert?"
        alert.informativeText = "This stops all alerts, removes the background agent and settings, and moves the app to the Trash. Sounds you added stay in ~/Library/Sounds."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Uninstall")
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        AgentControl.disable()
        try? SMAppService.mainApp.unregister()
        try? FileManager.default.removeItem(at: DiskAlert.supportFolder)
        try? FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
        NSApp.terminate(nil)
    }
}
