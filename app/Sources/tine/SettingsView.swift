import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var installer = SpecInstaller()

    // Re-read externally-owned state (Accessibility grant, login item) so the UI
    // reflects changes made outside the app without needing a relaunch.
    @State private var axTrusted = AXCaret.isTrusted
    @State private var startAtLogin = SMAppService.mainApp.status == .enabled
    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private let tints = ["blue", "purple", "green", "pink", "orange", "teal"]
    // (config value, display name). "" = the system monospaced font.
    private let fonts = [("", "System Monospaced"), ("Menlo", "Menlo"),
                         ("Monaco", "Monaco"), ("SF Mono", "SF Mono"),
                         ("Courier New", "Courier New")]
    private let shellLine = "source ~/.local/share/tine/tine.zsh"

    private var shellInstalled: Bool {
        FileManager.default.fileExists(atPath: "\(NSHomeDirectory())/.local/share/tine/tine.zsh")
    }

    var body: some View {
        let specCount = SpecInstaller.installedCount()
        Form {
            Section("Setup") {
                setupRow("Accessibility", ok: axTrusted,
                         detail: "Positions the panel at your cursor (Terminal & iTerm).") {
                    Button("Grant") {
                        AXCaret.ensureTrusted()
                        openPane("com.apple.preference.security?Privacy_Accessibility")
                    }
                }
                setupRow("Shell integration", ok: shellInstalled,
                         detail: shellLine) {
                    Button("Copy line") { copy(shellLine) }
                }
            }

            Section("General") {
                Toggle("Start at login", isOn: $startAtLogin)
                    .onChange(of: startAtLogin) { _, on in setStartAtLogin(on) }
                Toggle("Menu bar icon", isOn: bind(\.showMenuBarIcon))
            }

            Section("Appearance") {
                Toggle("Liquid glass", isOn: bind(\.glass))
                Picker("Accent", selection: bind(\.accentTintName)) {
                    ForEach(tints, id: \.self) { Text($0.capitalized).tag($0) }
                }
                Picker("Font", selection: bind(\.fontName)) {
                    ForEach(fonts, id: \.0) { Text($0.1).tag($0.0) }
                }
                LabeledContent("Font size") {
                    HStack(spacing: 6) {
                        TextField("", value: bind(\.fontSize), format: .number)
                            .frame(width: 46).multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                        Stepper("", value: bind(\.fontSize), in: 8...28, step: 1).labelsHidden()
                    }
                }
            }

            Section {
                LabeledContent("Max rows shown") {
                    HStack(spacing: 6) {
                        TextField("", value: bind(\.maxVisibleRows), format: .number)
                            .frame(width: 46).multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                        Stepper("", value: bind(\.maxVisibleRows), in: 1...40).labelsHidden()
                    }
                }
                Toggle("Complete command names", isOn: bind(\.firstTokenCompletion))
            } header: {
                Text("Suggestions")
            } footer: {
                Text("↑ ↓ move · Tab inserts the shared prefix · Enter accepts · Esc dismisses · **⌃K** toggles the detail pane")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Specs") {
                LabeledContent("Installed",
                               value: specCount > 0 ? "\(specCount) commands" : "None")
                HStack(spacing: 10) {
                    Button("Install / Update Specs") { installer.install() }
                        .disabled(installer.status == .running)
                    if installer.status == .running { ProgressView().controlSize(.small) }
                    installerStatus
                }
            }

            Section("Your specs") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Drop Fig `.js` specs in `override/<cmd>.js` (replaces a spec) or `extend/<cmd>.js` (adds to it) under this folder. Restart tine after changing this.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("Local specs folder", text: bind(\.localSpecsDir))
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospaced())
                        Button("Reveal") { revealLocalSpecs() }
                    }
                }
            }

            Section {
                Button("Quit tine", role: .destructive) { NSApplication.shared.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 600)
        .onReceive(refresh) { _ in
            axTrusted = AXCaret.isTrusted
        }
    }

    /// Register/unregister the app as a login item; revert the toggle to the real
    /// system state if the call fails (e.g. the user must approve in Login Items).
    private func setStartAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            startAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    @ViewBuilder private var installerStatus: some View {
        switch installer.status {
        case .idle, .running: EmptyView()
        case .done(let msg): Text(msg).foregroundStyle(.green).font(.caption)
        case .failed(let msg): Text(msg).foregroundStyle(.red).font(.caption).lineLimit(2)
        }
    }

    @ViewBuilder
    private func setupRow<Content: View>(
        _ title: String, ok: Bool, detail: String, @ViewBuilder action: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                action()
            }
            Spacer(minLength: 0)
        }
    }

    private func bind<V>(_ keyPath: WritableKeyPath<TineConfig, V>) -> Binding<V> {
        Binding(get: { state.config[keyPath: keyPath] },
                set: { state.config[keyPath: keyPath] = $0 })
    }

    private func openPane(_ path: String) {
        if let url = URL(string: "x-apple.systempreferences:\(path)") { NSWorkspace.shared.open(url) }
    }
    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
    private func revealLocalSpecs() {
        let dir = state.config.localSpecsDirExpanded
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }
}
