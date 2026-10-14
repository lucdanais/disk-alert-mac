import AppKit
import SwiftUI

/// A native pop-up menu of sounds. Like System Settings, the sound under the
/// pointer plays as you move through the open menu.
struct SoundMenu: NSViewRepresentable {
    @Binding var selection: String
    var leading: [String] = []      // e.g. "Default"
    var trailing: [String] = []     // e.g. "Mute", "Off"
    var custom: [String]
    /// The sound "Default" stands for, so it can be previewed too.
    var defaultSound: String? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.target = context.coordinator
        button.action = #selector(Coordinator.picked(_:))
        button.menu?.delegate = context.coordinator
        button.setContentHuggingPriority(.required, for: .horizontal)
        rebuild(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let signature = (leading + ["|"] + custom + ["|"] + trailing + ["|", selection, defaultSound ?? ""]).joined(separator: "\u{1}")
        if signature != context.coordinator.signature {
            rebuild(button, coordinator: context.coordinator)
            context.coordinator.signature = signature
        }
    }

    private func rebuild(_ button: NSPopUpButton, coordinator: Coordinator) {
        let menu = button.menu ?? NSMenu()
        menu.removeAllItems()
        menu.delegate = coordinator

        func add(_ names: [String]) {
            for name in names {
                let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                item.representedObject = name
                if name == "Default", let d = defaultSound {
                    item.title = "Default (\(d))"
                }
                menu.addItem(item)
            }
        }
        func separator() { if menu.items.last.map({ !$0.isSeparatorItem }) ?? false { menu.addItem(.separator()) } }

        add(leading)
        separator()
        add(Sounds.builtIn)
        if !custom.isEmpty { separator(); add(custom) }
        if !trailing.isEmpty { separator(); add(trailing) }

        let all = menu.items.compactMap { $0.representedObject as? String }
        if !all.contains(selection) {
            separator()
            add([selection])
        }
        if let item = menu.items.first(where: { ($0.representedObject as? String) == selection }) {
            button.select(item)
        }
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var parent: SoundMenu
        var signature = ""

        init(_ parent: SoundMenu) { self.parent = parent }

        @objc func picked(_ sender: NSPopUpButton) {
            guard let name = sender.selectedItem?.representedObject as? String else { return }
            parent.selection = name
        }

        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            guard let name = item?.representedObject as? String else { return }
            let sound = name == "Default" ? parent.defaultSound : name
            if let sound, Sounds.url(for: sound) != nil {
                SoundPreview.play(sound)
            } else {
                SoundPreview.stop()
            }
        }
    }
}

/// A labelled row with a sound menu, as used throughout Settings.
struct SoundRow: View {
    @EnvironmentObject var model: AppModel
    let title: String
    var subtitle: String? = nil
    @Binding var selection: String
    var leading: [String] = []
    var trailing: [String] = []
    var defaultSound: String? = nil

    var body: some View {
        LabeledContent {
            SoundMenu(selection: $selection, leading: leading, trailing: trailing,
                      custom: model.customSounds, defaultSound: defaultSound)
                .fixedSize()
        } label: {
            Text(title)
            if let subtitle { Text(subtitle) }
        }
    }
}
