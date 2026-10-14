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

// MARK: - Drives

/// One sound, or separate connect and eject sounds, for a drive or a drive type.
struct RuleEditor: View {
    @EnvironmentObject var model: AppModel
    @Binding var rule: DriveRule
    var defaultConnect: String
    var defaultEject: String

    var body: some View {
        if rule.split {
            SoundRow(title: "Connected", selection: $rule.connectSound,
                     leading: ["Default"], trailing: ["Mute"], defaultSound: defaultConnect)
            SoundRow(title: "Ejected", selection: $rule.ejectSound,
                     leading: ["Default"], trailing: ["Mute"], defaultSound: defaultEject)
        }
        Toggle("Separate connect and eject sounds", isOn: $rule.split)
    }
}

struct RuleHeader: View {
    @EnvironmentObject var model: AppModel
    let symbol: String
    let title: String
    let subtitle: String
    @Binding var rule: DriveRule
    var defaultSound: String

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
            Spacer()
            if !rule.split {
                SoundMenu(selection: $rule.sound, leading: ["Default"], trailing: ["Mute"],
                          custom: model.customSounds, defaultSound: defaultSound)
                    .fixedSize()
            }
        }
    }
}

struct DrivesTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(DriveCategory.allCases) { c in
                    let rule = model.ruleBinding(forCategory: c)
                    RuleHeader(symbol: c.symbol, title: c.title, subtitle: c.detail, rule: rule,
                               defaultSound: model.settings.connectSound)
                    RuleEditor(rule: rule, defaultConnect: model.settings.connectSound,
                               defaultEject: model.settings.ejectSound)
                }
            } header: {
                Text("Drive types")
            } footer: {
                Text("“Default” uses the sounds from General. Disk Alert recognizes SD cards in the built-in slot and most card readers.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if model.drives.isEmpty {
                    Text("Drives show up here after they connect once.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.drives) { drive in
                        let rule = model.ruleBinding(forDrive: drive.id)
                        RuleHeader(symbol: drive.category.symbol, title: drive.name, subtitle: subtitle(drive), rule: rule,
                                   defaultSound: model.settings.fallbackSound(connect: true, category: drive.category))
                        RuleEditor(rule: rule,
                                   defaultConnect: model.settings.fallbackSound(connect: true, category: drive.category),
                                   defaultEject: model.settings.fallbackSound(connect: false, category: drive.category))
                    }
                }
            } header: {
                Text("Your drives")
            } footer: {
                Text("A drive’s own sound wins over its type. “Mute” turns off connect and eject alerts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.size.width, height: SettingsLayout.size.height)
        .onAppear { model.refresh() }
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
                            Button("Remove") { model.removeSound(name) }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Your sounds")
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
