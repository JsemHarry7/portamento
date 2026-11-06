import AppKit
import SwiftUI

/// The runtimes `porta setup` installs, grouped the way a person thinks of them.
/// `keys` are prefixes of the names porta reports as missing.
struct Component: Identifiable {
    var name: String
    var detail: String
    var keys: [String]

    var id: String { name }

    static let all = [
        Component(name: "Wine 11.0 z CrossOveru", detail: "Ze zdrojáků CodeWeavers, s msync. Výchozí Wine.", keys: ["wine-cx-"]),
        Component(name: "Wine 11.21 Staging", detail: "Build od Gcenx s úpravami Portamenta.", keys: ["wine", "wine-11.", "wine-mods-"]),
        Component(name: "DXMT", detail: "Direct3D 10 a 11 přes Metal.", keys: ["dxmt"]),
        Component(name: "DXVK", detail: "Direct3D 10 a 11 přes Vulkan.", keys: ["dxvk"]),
        Component(name: "D3DMetal 3.0", detail: "Direct3D 12 od Applu, s Wine 7.7 z Game Porting Toolkitu (Gcenx).", keys: ["gcenx-gptk"]),
        Component(name: "KosmicKrisp", detail: "Vulkan na Metalu z Mesy.", keys: ["kosmickrisp-"]),
        Component(name: "Testy kompatibility", detail: "Malé programy, kterými Portamento ověřuje grafiku.", keys: ["selftests"]),
    ]

    func isMissing(_ missing: [String]) -> Bool {
        missing.contains { name in keys.contains { key in key.hasSuffix("-") || key.hasSuffix(".") ? name.hasPrefix(key) : name == key } }
    }
}

/// First run: what Portamento needs, and one button to get it.
struct SetupView: View {
    @Environment(Library.self) private var library

    private var missing: [String] { library.inventory.setup.missing }
    private var running: Bool { library.activity?.isRunning == true }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                    Text("Vítej v Portamentu")
                        .font(.system(.largeTitle, design: .serif, weight: .semibold))
                    Text("Než spustíš první hru, Portamento si stáhne Wine a vrstvy, které překládají grafiku Windows na Metal. Je to zhruba 800 MB a stačí to jednou.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 460)
                }

                if !library.requirements.isEmpty {
                    RequirementsBox()
                }

                Form {
                    Section("Co se nainstaluje") {
                        ForEach(Component.all) { component in
                            LabeledContent {
                                if component.isMissing(missing) {
                                    Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                                } else {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            } label: {
                                Text(component.name)
                                Text(component.detail)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(maxWidth: 520)

                if let activity = library.activity {
                    ActivityView(activity: activity)
                        .frame(maxWidth: 520)
                }

                Button {
                    Task { await library.runSetup() }
                } label: {
                    Label(running ? "Připravuji…" : "Připravit Portamento", systemImage: "arrow.down.circle.fill")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .disabled(running || !library.requirements.isEmpty)

                Text("Wine i grafické vrstvy pocházejí z otevřených projektů. Portamento je stahuje z jejich vydání na GitHubu a nic dalšího do systému neinstaluje.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Vítej")
    }
}

/// What the Mac needs before porta can run, with the way to get each.
struct RequirementsBox: View {
    @Environment(Library.self) private var library

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(library.requirements, id: \.self) { requirement in
                    switch requirement {
                    case .python:
                        row("Nástroje pro vývojáře od Applu",
                            "Portamento je potřebuje kvůli Pythonu. Instalace trvá pár minut.") {
                            Button("Nainstalovat…") { run("/usr/bin/xcode-select", ["--install"]) }
                        }
                    case .rosetta:
                        row("Rosetta 2",
                            "Wine pro Windows je program pro Intel. V Terminálu spusť: softwareupdate --install-rosetta") {
                            Button("Zkopírovat příkaz") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("softwareupdate --install-rosetta --agree-to-license", forType: .string)
                            }
                        }
                    }
                }
                Button("Zkontrolovat znovu", systemImage: "arrow.clockwise") {
                    Task { await library.checkRequirements() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
            .padding(6)
        } label: {
            Label("Nejdřív je potřeba", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .frame(maxWidth: 520)
    }

    private func row(_ title: String, _ detail: String, @ViewBuilder action: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            action()
        }
    }

    private func run(_ tool: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try? process.run()
    }
}

/// A long porta command: its current step, a progress bar, and the output on demand.
struct ActivityView: View {
    @Environment(Library.self) private var library
    var activity: Activity
    @StateObject private var state = ActivityState()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if activity.isRunning {
                    ProgressView().controlSize(.small)
                } else if activity.error == nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
                Text(activity.title).font(.headline)
                Spacer()
                if !activity.isRunning {
                    Button("Zavřít") { library.dismissActivity() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                }
            }
            Text(activity.error ?? activity.step)
                .font(.callout)
                .foregroundStyle(activity.error == nil ? Color.secondary : Color.red)
                .lineLimit(2)
                .textSelection(.enabled)
            if activity.isRunning {
                if let progress = activity.progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            DisclosureGroup("Výpis", isExpanded: $state.showLog) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(activity.lines.enumerated()), id: \.offset) { index, line in
                                Text(line).id(index)
                            }
                        }
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .onChange(of: activity.lines.count) { proxy.scrollTo(activity.lines.count - 1, anchor: .bottom) }
                }
            }
            .font(.callout)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
    }
}

final class ActivityState: ObservableObject {
    @Published var showLog = false
}
