import Combine
import SwiftUI

// View state lives in ObservableObjects rather than @State: @State is a macro in
// the macOS 27 SDK, and the Command Line Tools don't ship SwiftUI's macro plugin.

@main
struct PortamentoApp: App {
    private let library = Library()
    @StateObject private var content = ContentState()

    var body: some Scene {
        WindowGroup("Portamento") {
            ContentView()
                .environment(library)
                .environmentObject(content)
                .tint(Theme.accent)
                .task { await library.reload() }
                // an installer opened with Portamento (Finder's Open With, or `open -a`)
                .onOpenURL { url in
                    guard url.isFileURL, ["exe", "msi"].contains(url.pathExtension.lowercased()) else { return }
                    content.installing = InstallRequest(source: .installer(url))
                }
                .task {
                    // Keep "Běží" badges current; ps is cheap.
                    while !Task.isCancelled {
                        await library.refreshRunning()
                        try? await Task.sleep(for: .seconds(3))
                    }
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nainstalovat Steam…") { content.installing = InstallRequest(source: .steam) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Nainstalovat hru ze souboru…") { content.installing = InstallRequest(source: .installer(nil)) }
                    .keyboardShortcut("o")
                Divider()
                Button("Nový prázdný prefix…") { content.creatingPrefix = true }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .toolbar) {
                Button("Obnovit") { Task { await library.reload() } }
                    .keyboardShortcut("r")
            }
        }
    }
}

enum SidebarItem: Hashable {
    case library
    case prefix(String)
    case status
}

final class ContentState: ObservableObject {
    @Published var selection: SidebarItem? = .library
    @Published var creatingPrefix = false
    @Published var installing: InstallRequest?
}

struct ContentView: View {
    @Environment(Library.self) private var library
    @EnvironmentObject private var state: ContentState

    var body: some View {
        NavigationSplitView {
            List(selection: $state.selection) {
                Section {
                    SidebarLabel("Knihovna", symbol: "square.grid.2x2")
                        .badge(library.runningCount)
                        .tag(SidebarItem.library)
                }
                Section("Prefixy") {
                    ForEach(library.prefixes) { prefix in
                        SidebarLabel(prefix.name, symbol: "shippingbox").tag(SidebarItem.prefix(prefix.name))
                    }
                }
                Section("Systém") {
                    SidebarLabel("Stav a testy", symbol: "stethoscope").tag(SidebarItem.status)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .toolbar {
                Menu("Přidat", systemImage: "plus") {
                    Button("Nainstalovat Steam…", systemImage: "storefront") {
                        state.installing = InstallRequest(source: .steam)
                    }
                    Button("Nainstalovat hru ze souboru…", systemImage: "shippingbox") {
                        state.installing = InstallRequest(source: .installer(nil))
                    }
                    Divider()
                    Button("Nový prázdný prefix…", systemImage: "folder.badge.plus") { state.creatingPrefix = true }
                }
                .disabled(library.needsFirstSetup)
            }
        } detail: {
            if library.needsFirstSetup {
                SetupView()
            } else {
                switch state.selection {
                case .prefix(let name):
                    if let prefix = library.prefix(named: name) {
                        PrefixView(prefix: prefix)
                    }
                case .status:
                    StatusView()
                case .library, nil:
                    LibraryView { prefix in state.selection = .prefix(prefix.name) }
                }
            }
        }
        .sheet(isPresented: $state.creatingPrefix) { NewPrefixSheet() }
        .sheet(item: $state.installing) { request in InstallSheet(request: request) }
        .alert("Něco se nepovedlo", isPresented: Binding(get: { library.error != nil },
                                                        set: { if !$0 { library.error = nil } })) {
            Button("OK") { library.error = nil }
        } message: {
            Text(library.error ?? "")
        }
    }
}

/// A sidebar row whose icon takes Portamento's accent; the sidebar ignores .tint
/// and .listItemTint and would otherwise use the system accent.
struct SidebarLabel: View {
    var title: String
    var symbol: String

    init(_ title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.accent)
        }
    }
}
