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
    let category: DriveCategory

    var usedFraction: Double {
        total > 0 ? min(1, max(0, Double(total - free) / Double(total))) : 0
    }
}

/// Plays sound previews. One at a time, so hovering through a menu never piles sounds up.
enum SoundPreview {
    private static var player: NSSound?

    static func play(_ name: String) {
        guard let url = Sounds.url(for: name) else { return }
        player?.stop()
        player = NSSound(contentsOf: url, byReference: true)
        player?.play()
    }

    static func stop() { player?.stop() }
}

final class AppModel: ObservableObject {
    static let shared = Snapshots.isActive ? AppModel(sample: ()) : AppModel()

    /// True for the sample model used to draw README screenshots: nothing is saved or started.
    let isSample: Bool

    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue, !isSample else { return }
            Store.save(settings, to: DiskAlert.settingsURL)
            if settings.enabled != oldValue.enabled {
                settings.enabled ? AgentControl.enable() : AgentControl.disable()
            }
            if settings.appearance != oldValue.appearance { applyAppearance() }
        }
    }
    @Published var drives: [KnownDrive] = []
    @Published var mountedVolumes: [MountedVolume] = []
    @Published var customSounds: [String] = []
    @Published var bundledSounds: Set<String> = []
    @Published var loginStatus: SMAppService.Status = .notRegistered

    init() {
        isSample = false
        settings = Store.settings
        if !FileManager.default.fileExists(atPath: DiskAlert.settingsURL.path) {
            Store.save(settings, to: DiskAlert.settingsURL)
        }
        if settings.enabled { AgentControl.enable() }
        loginStatus = SMAppService.mainApp.status
        refresh()

        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Give the agent a moment to record the drive first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.refresh() }
            }
        }
    }

    /// Sample drives and sounds for screenshots.
    init(sample: Void) {
        isSample = true
        settings = AppSettings()
        let now = Date()
        drives = [
            KnownDrive(id: "a", name: "Media SSD", format: "APFS", capacity: 2_000_000_000_000, lastSeen: now, category: .drive),
            KnownDrive(id: "b", name: "EOS_DIGITAL", format: "ExFAT", capacity: 128_000_000_000, lastSeen: now.addingTimeInterval(-3600), category: .memoryCard)
        ]
        settings.driveRules["b"] = DriveRule(connect: "Hero", eject: "Default")
        mountedVolumes = [
            MountedVolume(url: URL(fileURLWithPath: "/Volumes/Media SSD"), name: "Media SSD",
                          free: 1_240_000_000_000, total: 2_000_000_000_000, category: .drive),
            MountedVolume(url: URL(fileURLWithPath: "/Volumes/EOS_DIGITAL"), name: "EOS_DIGITAL",
                          free: 41_800_000_000, total: 128_000_000_000, category: .memoryCard)
        ]
        customSounds = ["fart-reverb", "Shutter Click"]
        bundledSounds = ["fart-reverb"]
        loginStatus = .enabled
    }

    func refresh() {
        guard !isSample else { return }
        bundledSounds = Set(Self.bundledSoundFiles.map { $0.deletingPathExtension().lastPathComponent })
        let known = Store.drives
        drives = known.values.sorted { $0.lastSeen > $1.lastSeen }
        customSounds = Sounds.customNames
        mountedVolumes = Self.currentVolumes(known: known)
        loginStatus = SMAppService.mainApp.status
    }

    static func currentVolumes(known: [String: KnownDrive] = Store.drives) -> [MountedVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsEjectableKey,
                                      .volumeIsRemovableKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                      .volumeUUIDStringKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard url.path.hasPrefix("/Volumes/"), let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let external = v.volumeIsInternal == false || v.volumeIsEjectable == true || v.volumeIsRemovable == true
            guard external else { return nil }
            let name = v.volumeName ?? url.lastPathComponent
            let match = v.volumeUUIDString.flatMap { known[$0] } ?? known.values.first { $0.name == name }
            let category: DriveCategory = match?.category ?? (Self.isDiskImage(url) ? .diskImage : .drive)
            return MountedVolume(url: url, name: name,
                                 free: Int64(v.volumeAvailableCapacity ?? 0), total: Int64(v.volumeTotalCapacity ?? 0),
                                 category: category)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Disk images are never remembered as drives, so anything unknown and not removable is treated as one.
    private static func isDiskImage(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.volumeIsRemovableKey, .volumeIsLocalKey])
        return v?.volumeIsRemovable == false && v?.volumeIsLocal == true
    }

    // MARK: Rules

    func ruleBinding(forDrive id: String) -> Binding<DriveRule> {
        Binding(get: { self.settings.driveRules[id] ?? DriveRule() },
                set: { self.settings.driveRules[id] = $0 })
    }

    func ruleBinding(forCategory c: DriveCategory) -> Binding<DriveRule> {
        Binding(get: { self.settings.categoryRules[c.rawValue] ?? DriveRule() },
                set: { self.settings.categoryRules[c.rawValue] = $0 })
    }

    // MARK: Appearance

    func applyAppearance() {
        switch settings.appearance {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: Sounds

    static var bundledSoundFiles: [URL] {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Sounds") else { return [] }
        return (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    /// Puts the sounds that come with the app into ~/Library/Sounds whenever one is missing,
    /// so notifications can always play them. They can't be deleted from the app.
    func installBundledSounds() {
        guard !isSample else { return }
        for file in Self.bundledSoundFiles {
            let dest = Sounds.userFolder.appendingPathComponent(file.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.copyItem(at: file, to: dest)
            }
        }
        refresh()
    }

    /// Asks first, then moves the sound file to the Trash.
    func confirmDeleteSound(_ name: String) {
        guard !bundledSounds.contains(name) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Delete “\(name)”?"
        a.informativeText = "The sound file moves to the Trash and disappears from Disk Alert. Drives using it go back to Default."
        a.addButton(withTitle: "Cancel")
        let del = a.addButton(withTitle: "Delete")
        del.hasDestructiveAction = true
        guard a.runModal() == .alertSecondButtonReturn else { return }
        removeSound(name)
        for (k, r) in settings.driveRules {
            if r.connectSound == name { settings.driveRules[k]?.connectSound = "Default" }
            if r.ejectSound == name { settings.driveRules[k]?.ejectSound = "Default" }
        }
        for (k, r) in settings.categoryRules {
            if r.connectSound == name { settings.categoryRules[k]?.connectSound = "Default" }
            if r.ejectSound == name { settings.categoryRules[k]?.ejectSound = "Default" }
        }
        for key in [\AppSettings.connectSound, \AppSettings.ejectSound, \AppSettings.unsafeSound] where settings[keyPath: key] == name {
            settings[keyPath: key] = AppSettings()[keyPath: key]
        }
    }

    func removeSound(_ name: String) {
        guard let url = Sounds.url(for: name), url.path.hasPrefix(Sounds.userFolder.path) else { return }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        refresh()
    }

    func showSoundsFolder() {
        NSWorkspace.shared.open(Sounds.userFolder)
    }

    // MARK: Open at login

    var openAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            if on { SMAppService.openSystemSettingsLoginItems() }
        }
        loginStatus = SMAppService.mainApp.status
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
