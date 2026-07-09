import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var installer = SpecInstaller()

    // Re-read externally-owned state (Accessibility grant, login item) so the UI
    // reflects changes made outside the app without needing a relaunch.
    @State private var axTrusted = AXCaret.isTrusted
    @State private var selectedSpecDir: Int?
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
                Toggle("Open window at start", isOn: bind(\.openWindowAtStart))
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
                    Text("In each folder, drop Fig `.js` specs in `override/<cmd>.js` (replaces a spec) or `extend/<cmd>.js` (adds to it). Earlier folders win. Restart tine after changing.")
                        .font(.caption).foregroundStyle(.secondary)
                    List(selection: $selectedSpecDir) {
                        ForEach(state.config.localSpecsDirs.indices, id: \.self) { i in
                            TextField("Spec folder", text: bindDir(i),
                                      prompt: Text(verbatim: "~/.config/tine/specs"))
                                .font(.caption.monospaced())
                        }
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                    .frame(height: 92)
                    HStack(spacing: 2) {
                        Button { addDir() } label: { Image(systemName: "plus") }
                        Button { removeSelectedDir() } label: { Image(systemName: "minus") }
                            .disabled(selectedSpecDir == nil || state.config.localSpecsDirs.count <= 1)
                        Spacer()
                        Button("Reveal") { revealSelectedDir() }
                            .disabled(selectedSpecDir == nil)
                    }
                    .buttonStyle(.borderless)
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
    /// Two-way binding to one spec-folder path (writing through config saves it).
    private func bindDir(_ i: Int) -> Binding<String> {
        Binding(
            get: { state.config.localSpecsDirs.indices.contains(i) ? state.config.localSpecsDirs[i] : "" },
            set: { if state.config.localSpecsDirs.indices.contains(i) { state.config.localSpecsDirs[i] = $0 } }
        )
    }
    private func addDir() {
        state.config.localSpecsDirs.append("")
        selectedSpecDir = state.config.localSpecsDirs.count - 1
    }
    private func removeSelectedDir() {
        guard let i = selectedSpecDir, state.config.localSpecsDirs.indices.contains(i) else { return }
        state.config.localSpecsDirs.remove(at: i)
        selectedSpecDir = nil
    }
    private func revealSelectedDir() {
        guard let i = selectedSpecDir, state.config.localSpecsDirs.indices.contains(i) else { return }
        revealSpecs(state.config.localSpecsDirs[i])
    }
    private func revealSpecs(_ path: String) {
        let dir = (path as NSString).expandingTildeInPath
        guard !dir.isEmpty else { return }
        for sub in ["override", "extend"] {
            try? FileManager.default.createDirectory(atPath: "\(dir)/\(sub)", withIntermediateDirectories: true)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }
}
