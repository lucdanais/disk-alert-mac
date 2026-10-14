import AppKit
import Foundation

/// Checks GitHub Releases for a newer Disk Alert and installs it.
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "open-luc/disk-alert-mac"

    enum State: Equatable {
        case idle, checking, upToDate, available(String), downloading, failed(String)
    }

    @Published var state: State = .idle
    @Published var lastChecked: Date? = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date

    @Published var automatic: Bool = UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automatic, forKey: "autoUpdateCheck") }
    }

    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Checks once a day while the app runs, if automatic checks are on.
    func startAutomaticChecks() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            self?.checkIfDue()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.checkIfDue() }
    }

    private func checkIfDue() {
        guard automatic else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < 24 * 60 * 60 { return }
        check(userInitiated: false)
    }

    struct Release: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
        let assets: [Asset]
        struct Asset: Decodable { let name: String; let browser_download_url: String }
    }

    func check(userInitiated: Bool) {
        guard state != .checking, state != .downloading else { return }
        state = .checking
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                self.lastChecked = Date()
                UserDefaults.standard.set(self.lastChecked, forKey: "lastUpdateCheck")
                guard let data, error == nil,
                      let release = try? JSONDecoder().decode(Release.self, from: data) else {
                    self.state = .failed("Couldn’t reach GitHub.")
                    if userInitiated { self.alert("Couldn’t check for updates", "Check your internet connection and try again.") }
                    return
                }
                let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                guard Self.isNewer(latest, than: self.currentVersion) else {
                    self.state = .upToDate
                    if userInitiated {
                        self.alert("You’re up to date", "Disk Alert \(self.currentVersion) is the latest version.")
                    }
                    return
                }
                self.state = .available(latest)
                self.offer(release, version: latest)
            }
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func offer(_ release: Release, version: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Disk Alert \(version) is available"
        var notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 600 { notes = String(notes.prefix(600)) + "…" }
        a.informativeText = "You have \(currentVersion).\n\n" + (notes.isEmpty ? "" : notes)
        a.addButton(withTitle: "Install and Relaunch")
        a.addButton(withTitle: "Later")
        a.addButton(withTitle: "View on GitHub")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            guard let dmg = release.assets.first(where: { $0.name.hasSuffix(".dmg") }),
                  let url = URL(string: dmg.browser_download_url) else {
                state = .failed("This release has no installer.")
                alert("Couldn’t update", "This release has no .dmg installer attached.")
                return
            }
            install(from: url)
        case .alertThirdButtonReturn:
            if let url = URL(string: release.html_url) { NSWorkspace.shared.open(url) }
        default:
            break
        }
    }

    private func install(from url: URL) {
        state = .downloading
        URLSession.shared.downloadTask(with: url) { file, _, error in
            guard let file, error == nil else {
                DispatchQueue.main.async {
                    self.state = .failed("Download failed.")
                    self.alert("Couldn’t download the update", "Try again later.")
                }
                return
            }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("DiskAlertUpdate-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let dmg = work.appendingPathComponent("update.dmg")
            try? FileManager.default.moveItem(at: file, to: dmg)
            DispatchQueue.main.async { self.replaceAndRelaunch(dmg: dmg, work: work) }
        }.resume()
    }

    /// Hands the swap to a small script that waits for this app to quit, replaces it, and opens the new one.
    private func replaceAndRelaunch(dmg: URL, work: URL) {
        let target = Bundle.main.bundleURL.path
        let script = """
        set -e
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
        MNT="\(work.path)/mnt"
        mkdir -p "$MNT"
        hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MNT" "\(dmg.path)" >/dev/null
        APP="$(find "$MNT" -maxdepth 1 -name '*.app' | head -1)"
        launchctl bootout gui/$(id -u)/\(DiskAlert.agentLabel) 2>/dev/null || true
        rm -rf "\(target).old"
        mv "\(target)" "\(target).old"
        if ditto "$APP" "\(target)"; then rm -rf "\(target).old"; else mv "\(target).old" "\(target)"; fi
        hdiutil detach "$MNT" -quiet || true
        xattr -dr com.apple.quarantine "\(target)" 2>/dev/null || true
        open "\(target)"
        rm -rf "\(work.path)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed("Couldn’t start the installer.")
            alert("Couldn’t install the update", error.localizedDescription)
        }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    var statusText: String {
        switch state {
        case .checking: return "Checking…"
        case .downloading: return "Downloading update…"
        case .available(let v): return "Version \(v) is available"
        case .failed(let why): return why
        case .upToDate, .idle:
            if let d = lastChecked { return "Last checked " + d.formatted(.relative(presentation: .named)) }
            return "Not checked yet"
        }
    }
}
