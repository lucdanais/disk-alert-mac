import SwiftUI

struct MenuView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Disk Alert").font(.headline)
                Spacer()
                Text(model.settings.enabled ? "On" : "Paused")
                    .font(.caption)
                    .foregroundStyle(model.settings.enabled ? Color.green : Color.secondary)
                Toggle("Disk alerts", isOn: $model.settings.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }

            Divider()

            Text("CONNECTED NOW")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            if model.mountedVolumes.isEmpty {
                Text("No drives connected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.mountedVolumes) { v in
                        HStack(spacing: 10) {
                            Image(systemName: "externaldrive.fill")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(v.name).font(.callout)
                                if v.total > 0 {
                                    Text("\(Format.bytes(v.free)) free of \(Format.bytes(v.total))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button {
                                model.eject(v)
                            } label: {
                                Image(systemName: "eject.fill")
                            }
                            .buttonStyle(.borderless)
                            .help("Eject \(v.name)")
                            .accessibilityLabel("Eject \(v.name)")
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                    }
                }
                if model.mountedVolumes.count > 1 {
                    Button("Eject All…") { model.ejectAll() }
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.orange)
                }
            }

            Divider()

            Button("Settings…") { AppDelegate.shared?.showSettings() }
                .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Button("Quit Disk Alert") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                Text("Alerts keep running after you quit")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { model.refresh() }
    }
}
