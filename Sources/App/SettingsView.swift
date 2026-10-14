import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General", drives = "Drives", sounds = "Sounds"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .drives: return "externaldrive"
        case .sounds: return "speaker.wave.2"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { t in
                    Button {
                        tab = t
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: t.icon).font(.system(size: 17))
                            Text(t.rawValue).font(.caption)
                        }
                        .frame(width: 80, height: 50)
                        .contentShape(Rectangle())
                        .foregroundStyle(tab == t ? Color.accentColor : Color.secondary)
                        .background(RoundedRectangle(cornerRadius: 8).fill(tab == t ? Color.primary.opacity(0.08) : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 10)

            Divider()

            Group {
                switch tab {
                case .general: GeneralTab()
                case .drives: DrivesTab()
                case .sounds: SoundsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Text(model.launchAtLogin ? "Menu bar icon starts when you log in" : "Alerts start automatically when you log in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Test Alert") { AgentControl.sendTest() }
                Button("Uninstall…", role: .destructive) { model.uninstall() }
                    .foregroundStyle(.red)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 600, height: 680)
        .onAppear { model.refresh() }
    }
}

// MARK: - Shared pieces

struct SoundPicker: View {
    @EnvironmentObject var model: AppModel
    let title: String
    @Binding var selection: String
    var extras: [String] = []       // shown before the sound names, e.g. "Default"
    var trailing: [String] = []     // shown after, e.g. "Mute"

    var body: some View {
        HStack(spacing: 8) {
            Picker(title, selection: $selection) {
                ForEach(extras, id: \.self) { Text($0).tag($0) }
                if !extras.isEmpty { Divider() }
                ForEach(Sounds.builtIn, id: \.self) { Text($0).tag($0) }
                if !model.customSounds.isEmpty {
                    Divider()
                    ForEach(model.customSounds, id: \.self) { Text($0).tag($0) }
                }
                if !trailing.isEmpty { Divider() }
                ForEach(trailing, id: \.self) { Text($0).tag($0) }
                if !allOptions.contains(selection) { Text(selection).tag(selection) }
            }
            Button {
                model.preview(previewName)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(Sounds.url(for: previewName) == nil)
            .help("Preview")
            .accessibilityLabel("Preview \(title)")
        }
    }

    private var allOptions: [String] { extras + Sounds.builtIn + model.customSounds + trailing }

    private var previewName: String {
        if selection == "Default" { return model.settings.connectSound }
        return selection
    }
}

// MARK: - General

struct GeneralTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "externaldrive.fill.badge.checkmark")
                        .font(.system(size: 26))
                        .foregroundStyle(model.settings.enabled ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Disk alerts").font(.headline)
                        Text(model.settings.enabled
                             ? "Watching for drives. Keeps running when the app is closed."
                             : "Paused. No alerts until you turn this back on.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Disk alerts", isOn: $model.settings.enabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding(.vertical, 4)
            }

            Section("Default sounds") {
                SoundPicker(title: "Connected", selection: $model.settings.connectSound)
                SoundPicker(title: "Ejected", selection: $model.settings.ejectSound)
                SoundPicker(title: "Unplugged without ejecting", selection: $model.settings.unsafeSound, trailing: ["Off"])
            }

            Section("When a drive connects") {
                Toggle(isOn: $model.settings.showInfo) {
                    Text("Show drive info")
                    Text("Free space, capacity and format in the notification")
                }
                Toggle(isOn: $model.settings.openInFinder) {
                    Text("Open in Finder")
                    Text("Opens a Finder window for the drive")
                }
            }

            Section("Startup") {
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                    Text("Show menu bar icon at login")
                    Text("Alerts run at login either way")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Drives

struct DrivesTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                if model.drives.isEmpty {
                    Text("Drives show up here after they connect once.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.drives) { drive in
                        DriveRow(drive: drive, rule: model.ruleBinding(for: drive.id))
                    }
                }
            } header: {
                Text("Your drives")
            } footer: {
                Text("“Default” uses the sounds from the General tab. “Mute” turns off connect and eject alerts for that drive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Disk images") {
                VStack(alignment: .leading, spacing: 6) {
                    SoundPicker(title: "Installers and .dmg files", selection: $model.settings.diskImageSound,
                                extras: ["Default"], trailing: ["Mute"])
                    Text("Mute them, or give them their own sound")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct DriveRow: View {
    let drive: KnownDrive
    @Binding var rule: DriveRule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(drive.name)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !rule.split {
                    SoundPicker(title: "Sound", selection: $rule.sound, extras: ["Default"], trailing: ["Mute"])
                        .labelsHidden()
                        .frame(width: 170)
                }
            }
            Toggle("Separate connect and eject sounds", isOn: $rule.split)
                .font(.caption)
                .padding(.leading, 28)
            if rule.split {
                VStack(spacing: 6) {
                    SoundPicker(title: "Connected", selection: $rule.connectSound, extras: ["Default"], trailing: ["Mute"])
                    SoundPicker(title: "Ejected", selection: $rule.ejectSound, extras: ["Default"], trailing: ["Mute"])
                }
                .padding(.leading, 28)
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts: [String] = []
        if !drive.format.isEmpty { parts.append(drive.format) }
        if drive.capacity > 0 { parts.append(Format.bytes(drive.capacity)) }
        parts.append("last seen " + drive.lastSeen.formatted(.relative(presentation: .named)))
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
                    Text("No sounds added yet. Drag any audio file here, or click Add Sound.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.customSounds, id: \.self) { name in
                        HStack(spacing: 10) {
                            Button { model.preview(name) } label: { Image(systemName: "play.fill") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Preview \(name)")
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
                        .controlSize(.small)
                }
            } footer: {
                HStack {
                    Text("Saved in ~/Library/Sounds and converted so notifications can play them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") { model.showSoundsFolder() }
                        .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(12)
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
    }
}
