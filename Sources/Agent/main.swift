import Cocoa
import DiskArbitration
import UserNotifications

// The background agent. It runs as a tiny, windowless process started by launchd,
// watches drives with Disk Arbitration and posts the notifications. It keeps running
// when the Disk Alert menu bar app is closed.

struct Volume {
    let bsd: String
    let id: String
    let name: String
    let url: URL
    let isImage: Bool
}

enum Event { case connect, eject, unsafe }

final class Monitor: NSObject, UNUserNotificationCenterDelegate {
    private var session: DASession?
    private var mounted: [String: Volume] = [:]      // keyed by BSD name, e.g. disk5s1
    private var ejectRequested: Set<String> = []
    private var ready = false
    private var players: [NSSound] = []

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskAppearedCallback(session, nil, { disk, ctx in
            Monitor.from(ctx).update(disk)
        }, ctx)
        DARegisterDiskDescriptionChangedCallback(session, nil, kDADiskDescriptionWatchVolumePath.takeUnretainedValue(), { disk, _, ctx in
            Monitor.from(ctx).update(disk)
        }, ctx)
        DARegisterDiskDisappearedCallback(session, nil, { disk, ctx in
            Monitor.from(ctx).disappeared(disk)
        }, ctx)
        // Called when anything asks the system to unmount a volume (Finder eject,
        // the Disk Alert menu, diskutil). Pulling the cable never asks, which is how
        // an unsafe removal is told apart from a proper eject.
        DARegisterDiskUnmountApprovalCallback(session, nil, { disk, ctx in
            Monitor.from(ctx).unmountRequested(disk)
            return nil
        }, ctx)

        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        // Drives already plugged in when the agent starts are noted silently.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.ready = true }
    }

    static func from(_ ctx: UnsafeMutableRawPointer?) -> Monitor {
        Unmanaged<Monitor>.fromOpaque(ctx!).takeUnretainedValue()
    }

    // MARK: Disk events

    private func bsdName(_ disk: DADisk) -> String? {
        guard let c = DADiskGetBSDName(disk) else { return nil }
        return String(cString: c)
    }

    private func volume(for disk: DADisk) -> Volume? {
        guard let bsd = bsdName(disk),
              let desc = DADiskCopyDescription(disk) as? [String: Any],
              let url = desc[kDADiskDescriptionVolumePathKey as String] as? URL,
              url.path.hasPrefix("/Volumes/") else { return nil }

        let model = (desc[kDADiskDescriptionDeviceModelKey as String] as? String) ?? ""
        let isImage = model.trimmingCharacters(in: .whitespaces) == "Disk Image"
        let internalDrive = (desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool) ?? false
        if internalDrive && !isImage { return nil }

        let name = (desc[kDADiskDescriptionVolumeNameKey as String] as? String) ?? url.lastPathComponent
        var id = name
        if let raw = desc[kDADiskDescriptionVolumeUUIDKey as String],
           CFGetTypeID(raw as CFTypeRef) == CFUUIDGetTypeID(),
           let text = CFUUIDCreateString(kCFAllocatorDefault, (raw as! CFUUID)) {
            id = text as String
        }
        return Volume(bsd: bsd, id: id, name: name, url: url, isImage: isImage)
    }

    func update(_ disk: DADisk) {
        guard let bsd = bsdName(disk) else { return }
        if let vol = volume(for: disk) {
            if mounted[bsd] == nil {
                mounted[bsd] = vol
                if ready { fire(.connect, vol) }
            }
        } else if let vol = mounted.removeValue(forKey: bsd) {
            // The volume is no longer mounted.
            let proper = ejectRequested.remove(bsd) != nil
            fire(proper ? .eject : .unsafe, vol)
        }
    }

    func disappeared(_ disk: DADisk) {
        guard let bsd = bsdName(disk) else { return }
        ejectRequested.remove(bsd)
        if let vol = mounted.removeValue(forKey: bsd) {
            // Gone while still mounted: unplugged without ejecting.
            fire(.unsafe, vol)
        }
    }

    func unmountRequested(_ disk: DADisk) {
        if let bsd = bsdName(disk) { ejectRequested.insert(bsd) }
    }

    // MARK: Notifications

    private enum SoundChoice { case muted, silent, named(String) }

    private func choice(_ event: Event, _ vol: Volume, _ s: AppSettings) -> SoundChoice {
        let fallback: String
        switch event {
        case .connect: fallback = s.connectSound
        case .eject: fallback = s.ejectSound
        case .unsafe: fallback = s.unsafeSound
        }

        var pick = "Default"
        if event != .unsafe {
            if vol.isImage {
                pick = s.diskImageSound
            } else if let rule = s.driveRules[vol.id] {
                pick = rule.split ? (event == .connect ? rule.connectSound : rule.ejectSound) : rule.sound
            }
        }
        if pick == "Mute" { return .muted }
        let name = pick == "Default" ? fallback : pick
        if name == "Off" || name == "None" { return .silent }
        return .named(name)
    }

    private func details(_ vol: Volume) -> (info: String, format: String, total: Int64) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey]
        let values = try? vol.url.resourceValues(forKeys: keys)
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let free = Int64(values?.volumeAvailableCapacity ?? 0)
        let format = values?.volumeLocalizedFormatDescription ?? ""
        var parts: [String] = []
        if total > 0 { parts.append("\(Format.bytes(free)) free of \(Format.bytes(total))") }
        if !format.isEmpty { parts.append(format) }
        return (parts.joined(separator: " · "), format, total)
    }

    func fire(_ event: Event, _ vol: Volume) {
        let s = Store.settings
        guard s.enabled else { return }

        var body = ""
        switch event {
        case .connect:
            let d = details(vol)
            if !vol.isImage {
                Store.remember(KnownDrive(id: vol.id, name: vol.name, format: d.format, capacity: d.total, lastSeen: Date()))
            }
            if s.showInfo { body = d.info }
            Store.log(HistoryEvent(date: Date(), name: vol.name, kind: .connected))
        case .eject:
            body = "Safe to unplug"
            Store.log(HistoryEvent(date: Date(), name: vol.name, kind: .ejected))
        case .unsafe:
            body = "Unplugged before ejecting. Files may be damaged."
            Store.log(HistoryEvent(date: Date(), name: vol.name, kind: .unsafe))
        }

        let sound = choice(event, vol, s)
        if case .muted = sound { return }

        let content = UNMutableNotificationContent()
        switch event {
        case .connect: content.title = s.connectTitle
        case .eject: content.title = s.ejectTitle
        case .unsafe: content.title = s.unsafeTitle
        }
        content.subtitle = vol.name
        content.body = body

        if case .named(let name) = sound, let file = Sounds.url(for: name) {
            if s.playSoundDirectly {
                play(file)
            } else {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(file.lastPathComponent))
            }
        }

        post(content)

        if event == .connect && s.openInFinder {
            NSWorkspace.shared.open(vol.url)
        }
    }

    private func post(_ content: UNMutableNotificationContent) {
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func play(_ url: URL) {
        guard let sound = NSSound(contentsOf: url, byReference: true) else { return }
        players.append(sound)
        if players.count > 8 { players.removeFirst() }
        sound.play()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    // MARK: Test

    func sendTest() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            DispatchQueue.main.async {
                let s = Store.settings
                let content = UNMutableNotificationContent()
                content.title = s.connectTitle
                content.subtitle = "Test Drive"
                content.body = "This is how alerts will look."
                if let file = Sounds.url(for: s.connectSound) {
                    if s.playSoundDirectly { self.play(file) }
                    else { content.sound = UNNotificationSound(named: UNNotificationSoundName(file.lastPathComponent)) }
                }
                self.post(content)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let monitor = Monitor()
if CommandLine.arguments.contains("--test") {
    monitor.sendTest()
} else {
    monitor.start()
}
app.run()
