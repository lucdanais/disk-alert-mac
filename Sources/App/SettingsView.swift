import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SettingsLayout {
    static let size = CGSize(width: 580, height: 640)
}

// MARK: - General

struct GeneralTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Disk alerts").font(.headline)
                        Text(model.settings.enabled
                             ? "Watching for drives. Keeps running when the app is closed."
                             : "Paused. No alerts until you turn this back on.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Disk alerts", isOn: $model.settings.enabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding(.vertical, 4)
            }

            Section {
                SoundRow(title: "Connected", selection: $model.settings.connectSound)
                SoundRow(title: "Ejected", selection: $model.settings.ejectSound)
                SoundRow(title: "Unplugged without ejecting", subtitle: "Plays even for muted drives",
                         selection: $model.settings.unsafeSound, trailing: ["Off"])
            } header: {
                Text("Sounds")
            } footer: {
                Text("Move the pointer over a sound in the menu to hear it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("When a drive connects") {
                Toggle(isOn: $model.settings.showInfo) {
                    Text("Show drive info")
                    Text("Free space, capacity and format in the notification")
                }
                Toggle(isOn: $model.settings.openInFinder) {
                    Text("Open in Finder automatically")
                    Text("Clicking the notification always opens the drive")
                }
            }

            Section("App") {
                Toggle(isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) })) {
                    Text("Open at login")
                    Text("Shows Disk Alert in the menu bar when you log in. Alerts run at login either way.")
                }
                if model.loginStatus == .requiresApproval {
                    LabeledContent {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    } label: {
                        Text("Needs your approval")
                        Text("Turn on Disk Alert in System Settings › General › Login Items")
                    }
                }
                Picker("Appearance", selection: $model.settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            UpdatesSection()

            Section {
                HStack {
                    Button("Send Test Alert") { AgentControl.sendTest() }
                    Spacer()
                    Button("Uninstall Disk Alert…", role: .destructive) { model.uninstall() }
                }
            } footer: {
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.size.width, height: SettingsLayout.size.height)
        .onAppear { model.refresh() }
    }
}

struct UpdatesSection: View {
    @ObservedObject var updater = Updater.shared

    var body: some View {
        Section("Updates") {
            LabeledContent {
                Button("Check for Updates") { updater.check(userInitiated: true) }
                    .disabled(updater.state == .checking || updater.state == .downloading)
            } label: {
                Text("Disk Alert \(updater.currentVersion)")
                Text(updater.statusText)
            }
            Toggle(isOn: $updater.automatic) {
                Text("Check automatically")
                Text("Once a day. You’re always asked before anything installs.")
            }
        }
    }
}

// MARK: - Drives

/// A drive or drive type: its name, then a Connected and an Ejected sound menu.
struct RuleBlock: View {
    @EnvironmentObject var model: AppModel
    let symbol: String
    let title: String
    let subtitle: String
    @Binding var rule: DriveRule
    var defaultConnect: String
    var defaultEject: String
    var onForget: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            if let onForget {
                Spacer()
                Button(action: onForget) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Forget this drive")
                .accessibilityLabel("Forget \(title)")
            }
        }
        SoundRow(title: "Connected", selection: $rule.connectSound,
                 leading: ["Default"], trailing: ["Mute"], defaultSound: defaultConnect)
        SoundRow(title: "Ejected", selection: $rule.ejectSound,
                 leading: ["Default"], trailing: ["Mute"], defaultSound: defaultEject)
    }
}

struct DrivesTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            ForEach(Array(DriveCategory.allCases.enumerated()), id: \.element) { i, c in
                Section {
                    RuleBlock(symbol: c.symbol, title: c.title, subtitle: c.detail,
                              rule: model.ruleBinding(forCategory: c),
                              defaultConnect: model.settings.connectSound,
                              defaultEject: model.settings.ejectSound)
                } header: {
                    if i == 0 { Text("Drive types") }
                } footer: {
                    if i == DriveCategory.allCases.count - 1 {
                        Text("“Default” follows the sounds in General. SD cards are recognized in the built-in slot and most card readers.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if model.drives.isEmpty {
                Section("Your drives") {
                    Text("Drives show up here after they connect once.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(Array(model.drives.enumerated()), id: \.element.id) { i, drive in
                    Section {
                        RuleBlock(symbol: drive.category.symbol, title: drive.name, subtitle: subtitle(drive),
                                  rule: model.ruleBinding(forDrive: drive.id),
                                  defaultConnect: model.settings.fallbackSound(connect: true, category: drive.category),
                                  defaultEject: model.settings.fallbackSound(connect: false, category: drive.category),
                                  onForget: { confirmForget(drive) })
                    } header: {
                        if i == 0 { Text("Your drives") }
                    } footer: {
                        if i == model.drives.count - 1 {
                            Text("“Default” follows the drive’s type, then General. “Mute” silences that alert. The − button forgets a drive and its sounds; it comes back the next time it’s plugged in.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.size.width, height: SettingsLayout.size.height)
        .onAppear { model.refresh() }
    }

    private func confirmForget(_ drive: KnownDrive) {
        let a = NSAlert()
        a.messageText = "Forget “\(drive.name)”?"
        a.informativeText = "Its sounds go back to Default and it leaves this list. It shows up again the next time you plug it in."
        a.addButton(withTitle: "Forget")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { model.forgetDrive(drive.id) }
    }

    private func subtitle(_ drive: KnownDrive) -> String {
        var parts: [String] = []
        if !drive.format.isEmpty { parts.append(drive.format) }
        if drive.capacity > 0 { parts.append(Format.bytes(drive.capacity)) }
        parts.append("seen " + drive.lastSeen.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Sounds

struct SoundsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var dropping = false

    var body: some View {
        Form {
            Section {
                if model.customSounds.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.badge.plus")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                        Text("No sounds added yet")
                            .font(.headline)
                        Text("Drag any audio file here, or click Add Sound.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    ForEach(model.customSounds, id: \.self) { name in
                        HStack(spacing: 10) {
                            Button { SoundPreview.play(name) } label: {
                                Image(systemName: "play.fill")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Play \(name)")
                            Text(name)
                            Spacer()
                            if model.bundledSounds.contains(name) {
                                Text("Included")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                            } else {
                                Button("Delete…", role: .destructive) { model.confirmDeleteSound(name) }
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Custom sounds")
                    Spacer()
                    Button("Add Sound…") { model.chooseSounds() }
                }
            } footer: {
                HStack {
                    Text("Saved in ~/Library/Sounds and converted so notifications can play them.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") { model.showSoundsFolder() }
                }
            }
        }
        .formStyle(.grouped)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(14)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { model.addSound(from: url) }
                }
            }
            return true
        }
        .frame(width: SettingsLayout.size.width, height: SettingsLayout.size.height)
        .onAppear { model.refresh() }
    }
}
