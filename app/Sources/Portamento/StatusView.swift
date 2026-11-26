import SwiftUI

struct StatusView: View {
    @Environment(Library.self) private var library
    @Environment(AppUpdater.self) private var updater
    @EnvironmentObject private var content: ContentState
    @StateObject private var runtimes = RuntimeBannerState()
    private let tests = ["d3d9", "d3d11", "d3d12", "vulkan", "opengl"]

    var body: some View {
        Form {
            Section("Portamento") {
                LabeledContent("Verze", value: AppUpdater.current)
                HStack {
                    if let release = updater.release, AppUpdater.isNewer(release.version, than: AppUpdater.current) {
                        Label("Je k dispozici \(release.version)", systemImage: "sparkles").foregroundStyle(Theme.accent)
                    }
                    Spacer()
                    Button("Vyhledat aktualizace…") {
                        content.showingUpdate = true
                        Task { await updater.check() }
                    }
                    .disabled(updater.isBusy)
                }
            }
            Section {
                if !library.needsSetup {
                    Label("Všechno je nainstalované a aktuální", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    ForEach(Component.all.filter { $0.isMissing(library.inventory.setup.missing) }) { component in
                        LabeledContent(component.name) {
                            Text("chybí").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Component.all.filter { $0.isMissing(library.runtimeUpdates) }) { component in
                        LabeledContent(component.name) {
                            Text("nová verze").foregroundStyle(Theme.accent)
                        }
                    }
                }
                if let activity = library.activity, activity.title == Activity.setupTitle {
                    ActivityView(activity: activity)
                }
            } header: {
                HStack {
                    Text("Runtimy")
                    Spacer()
                    if !library.inventory.setup.missing.isEmpty {
                        Button("Doinstalovat") { Task { await library.runSetup() } }
                            .disabled(library.activity?.isRunning == true)
                    } else if !library.runtimeUpdates.isEmpty {
                        Button("Aktualizovat") {
                            if library.runningPrefixes.isEmpty {
                                Task { await library.runSetup() }
                            } else {
                                runtimes.confirmingStop = true
                            }
                        }
                        .disabled(library.activity?.isRunning == true)
                        .confirmationDialog("Ukončit běžící hry a aktualizovat?", isPresented: $runtimes.confirmingStop) {
                            Button("Ukončit a aktualizovat", role: .destructive) { Task { await library.updateRuntimes() } }
                        } message: {
                            Text("Nové verze nahradí soubory, které teď používá \(library.runningPrefixes.map(\.name).formatted(.list(type: .and))). Neuložený postup ve hrách se ztratí.")
                        }
                    }
                }
            }
            Section("Wine") {
                ForEach(library.inventory.wines.keys.sorted(), id: \.self) { wine in
                    installed(Theme.wineName(wine), library.inventory.wines[wine] == true)
                }
            }
            Section("Vulkan") {
                ForEach(library.inventory.vulkan.keys.sorted(), id: \.self) { driver in
                    installed(Theme.vulkanName(driver), library.inventory.vulkan[driver] == true)
                }
            }
            Section {
                if let selftest = library.selftest {
                    results(selftest.results)
                } else {
                    Text("Testy ještě neproběhly.").foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Testy kompatibility")
                    Spacer()
                    if library.isTesting {
                        ProgressView().controlSize(.small)
                    }
                    Button(library.isTesting ? LocalizedStringKey("Testuje se…") : "Spustit testy") {
                        Task { await library.runSelftest() }
                    }
                    .disabled(library.isTesting)
                }
            } footer: {
                if let date = library.selftest?.date {
                    Text("Naposledy \(date.formatted(date: .abbreviated, time: .shortened)). Testy na chvíli otevírají okna, fps jsou pro jednoduchou scénu, ne pro hry.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Stav a testy")
    }

    private func installed(_ name: String, _ ok: Bool) -> some View {
        LabeledContent(name) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : .secondary)
        }
    }

    /// One row per Wine / backend / Vulkan driver, one column per API.
    private func results(_ results: [SelftestResult]) -> some View {
        let rows = Dictionary(grouping: results) { "\($0.wine) · \(Theme.gfxName($0.gfx)) · \(Theme.vulkanName($0.vulkan))" }
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Text("")
                ForEach(tests, id: \.self) { Text($0.uppercased()).font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(rows.keys.sorted(), id: \.self) { row in
                GridRow {
                    Text(row).font(.callout)
                    ForEach(tests, id: \.self) { test in
                        cell(rows[row]?.first { $0.test == test })
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ result: SelftestResult?) -> some View {
        if let result {
            Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.octagon")
                .foregroundStyle(result.passed ? .green : .red)
                .help(result.detail.isEmpty ? result.status : result.detail)
        } else {
            Text("–").foregroundStyle(.tertiary)
        }
    }
}
