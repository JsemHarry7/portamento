import AppKit
import Combine
import SwiftUI

final class LibraryState: ObservableObject {
    @Published var query = ""
    @Published var selected: String?  // GameEntry id
    @Published var inspecting = false
}

struct LibraryView: View {
    @Environment(Library.self) private var library
    @EnvironmentObject private var content: ContentState
    var showPrefix: (Prefix) -> Void
    @StateObject private var state = LibraryState()

    private var shown: [GameEntry] {
        let query = state.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return library.games }
        return library.games.filter { $0.name.localizedStandardContains(query) }
    }

    private var selectedGame: GameEntry? {
        library.games.first { $0.id == state.selected }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.tileWidth), spacing: Theme.gridSpacing)],
                      spacing: Theme.gridSpacing) {
                ForEach(shown) { game in
                    GameTile(game: game, isSelected: game.id == state.selected, showPrefix: showPrefix) {
                        state.selected = game.id
                        state.inspecting = true
                    }
                }
            }
            .padding(Theme.contentPadding)
        }
        // A click on the empty space between tiles clears the selection.
        .background { Color.clear.contentShape(.rect).onTapGesture { state.selected = nil } }
        .overlay {
            if library.games.isEmpty {
                ContentUnavailableView {
                    Label("Zatím tu nic není", systemImage: "gamecontroller")
                } description: {
                    Text("Nainstaluj Steam a hry z něj, nebo hru z vlastního instalátoru.")
                } actions: {
                    Button("Nainstalovat Steam") { content.installing = InstallRequest(source: .steam) }
                        .buttonStyle(.glassProminent)
                    Button("Hra ze souboru…") { content.installing = InstallRequest(source: .installer(nil)) }
                        .buttonStyle(.glass)
                }
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: state.query)
            }
        }
        .safeAreaInset(edge: .top) {
            if library.needsSetup || library.activity != nil {
                RuntimeBanner().padding(.horizontal, Theme.contentPadding).padding(.top, 8)
            }
        }
        .searchable(text: $state.query, placement: .toolbar, prompt: "Hledat v knihovně")
        .navigationTitle("Knihovna")
        .navigationSubtitle(subtitle)
        .inspector(isPresented: $state.inspecting) {
            Group {
                if let game = selectedGame {
                    GameInspector(game: game, showPrefix: showPrefix)
                } else {
                    ContentUnavailableView("Vyber hru", systemImage: "hand.tap",
                                           description: Text("Klikni na dlaždici v knihovně."))
                }
            }
            .inspectorColumnWidth(min: 270, ideal: 310, max: 400)
            .toolbar {
                Button("Podrobnosti", systemImage: "info.circle") { state.inspecting.toggle() }
                    .help(state.inspecting ? LocalizedStringKey("Skrýt podrobnosti") : "Zobrazit podrobnosti")
            }
        }
    }

    private var subtitle: String {
        let games = library.games.count
        let items = Theme.count(games, "položka", "položky", "položek")
        let running = library.runningCount
        return running > 0 ? String(localized: "\(items) · \(running) běží") : items
    }
}

/// A runtime update porta can install (a new KosmicKrisp, say), or the one installing.
struct RuntimeBanner: View {
    @Environment(Library.self) private var library

    private var names: String {
        Component.all.filter { $0.isMissing(library.inventory.setup.missing) }.map(\.name).formatted(.list(type: .and))
    }

    var body: some View {
        if let activity = library.activity, activity.title == Activity.setupTitle {
            ActivityView(activity: activity)
        } else if library.needsSetup {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nové verze ke stažení").font(.headline)
                    Text(names).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Stáhnout") { Task { await library.runSetup() } }
                    .buttonStyle(.glassProminent)
                    .disabled(library.activity?.isRunning == true)
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }
}

// MARK: - Tile

final class TileState: ObservableObject {
    @Published var cover: NSImage?
    @Published var hovering = false
}

struct GameTile: View {
    @Environment(Library.self) private var library
    var game: GameEntry
    var isSelected: Bool
    var showPrefix: (Prefix) -> Void
    var select: () -> Void
    @StateObject private var state = TileState()

    private var preferred: LibraryItem { library.defaultVariant(of: game) }
    private var running: Bool { library.isRunning(game) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let cover = state.cover {
                    Image(nsImage: cover).resizable().scaledToFill()
                } else {
                    Placeholder(program: preferred.program, compact: false)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(Theme.tileAspect, contentMode: .fit)
            // Quick launch sits in a corner, so a click on the cover itself only selects.
            .overlay(alignment: .bottomLeading) {
                if state.hovering && !running {
                    HStack(spacing: 4) {
                        Button("Spustit", systemImage: "play.fill") { launch(preferred) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.glassProminent)
                            .help("Spustit (\(Theme.shortVariantName(preferred)))")
                        if game.variants.count > 1 {
                            Menu("Režimy", systemImage: "chevron.down") { variantButtons { launch($0) } }
                                .labelStyle(.iconOnly)
                                .menuIndicator(.hidden)
                                .buttonStyle(.glass)
                                .fixedSize()
                                .help("Spustit v jiném režimu")
                        }
                    }
                    .controlSize(.large)
                    .padding(8)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottomLeading) {
                // Bottom corner: the top of a cover is usually the game's logo.
                if running { RunningBadge().padding(8) }
            }
            .clipShape(.rect(cornerRadius: Theme.tileCorner))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.tileCorner + 3)
                    .strokeBorder(Theme.accent, lineWidth: 3)
                    .padding(-4)
                    .opacity(isSelected ? 1 : 0)
            }
            .shadow(color: .black.opacity(state.hovering ? 0.25 : 0.12), radius: state.hovering ? 10 : 4, y: 3)
            .scaleEffect(state.hovering ? 1.02 : 1)
            .animation(.snappy(duration: 0.18), value: state.hovering)
            .contentShape(.rect(cornerRadius: Theme.tileCorner))
            .onHover { state.hovering = $0 }

            Text(Theme.displayName(preferred.program)).font(.headline).lineLimit(1)
            HStack(spacing: 4) {
                Text(Theme.shortVariantName(preferred)).lineLimit(1)
                if game.variants.count > 1 {
                    Text("· \(Theme.modes(game.variants.count))").foregroundStyle(.tertiary).fixedSize()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onTapGesture(count: 2) { launch(preferred) }
        .onTapGesture(perform: select)
        .contextMenu {
            if running {
                Button("Ukončit", systemImage: "stop.fill") { Task { await library.stop(game) } }
            } else {
                Button("Spustit", systemImage: "play") { launch(preferred) }
                Button("Spustit s ukazatelem výkonu", systemImage: "gauge.with.dots.needle.67percent") {
                    launch(preferred, hud: true)
                }
            }
            if game.variants.count > 1 {
                Menu("Spustit v režimu") { variantButtons { launch($0) } }
                Menu("Výchozí režim") { variantButtons { library.makeDefault($0) } }
            }
            Divider()
            Button("Podrobnosti", systemImage: "info.circle", action: select)
            Button("Zobrazit prefix", systemImage: "shippingbox") { showPrefix(preferred.prefix) }
        }
        .task(id: game.art) { state.cover = await CoverArt.image(.cover, in: game.art) }
    }

    /// One button per way of running the game, the default one ticked.
    @ViewBuilder
    private func variantButtons(_ action: @escaping (LibraryItem) -> Void) -> some View {
        ForEach(game.variants) { variant in
            Button {
                action(variant)
            } label: {
                if variant == preferred {
                    Label(Theme.variantName(variant), systemImage: "checkmark")
                } else {
                    Text(Theme.variantName(variant))
                }
            }
        }
    }

    private func launch(_ item: LibraryItem, hud: Bool = false) {
        Task { await library.launch(item, hud: hud) }
    }
}

/// Stands in for missing artwork: the palette's gradient, a symbol and the name.
struct Placeholder: View {
    var program: Program
    var compact: Bool

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.placeholder)
            VStack(spacing: compact ? 6 : 12) {
                Image(systemName: Theme.symbol(for: program))
                    .font(.system(size: compact ? 30 : 40, weight: .ultraLight))
                if !compact {
                    Text(Theme.displayName(program))
                        .font(.system(.title3, design: .serif, weight: .medium))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 12)
                }
            }
            .foregroundStyle(Theme.pale.opacity(0.9))
        }
    }
}

struct RunningBadge: View {
    var body: some View {
        Label {
            Text("Běží")
        } icon: {
            Circle().fill(.green).frame(width: 7, height: 7)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - Inspector

final class InspectorState: ObservableObject {
    @Published var hero: NSImage?
    @Published var logo: NSImage?
}

struct GameInspector: View {
    @Environment(Library.self) private var library
    var game: GameEntry
    var showPrefix: (Prefix) -> Void
    @StateObject private var state = InspectorState()

    private var preferred: LibraryItem { library.defaultVariant(of: game) }
    private var running: Bool { library.isRunning(game) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 20) {
                    actions
                    compatibilityNote
                    if game.variants.count > 1 { modes }
                    details
                    if showsPicture { picture }
                    links
                }
                .padding(16)
            }
        }
        .task(id: game.art) {
            state.hero = await CoverArt.image(.hero, in: game.art)
            state.logo = await CoverArt.image(.logo, in: game.art)
        }
    }

    /// Steam's wide hero image with the game's logo on it, or the placeholder.
    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            if let hero = state.hero {
                Color.clear.overlay { Image(nsImage: hero).resizable().scaledToFill() }.clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            } else {
                Placeholder(program: preferred.program, compact: true)
            }
            HStack(alignment: .bottom) {
                if let logo = state.logo {
                    Image(nsImage: logo).resizable().scaledToFit()
                        .frame(maxWidth: 190, maxHeight: 64, alignment: .bottomLeading)
                        .shadow(color: .black.opacity(0.5), radius: 6)
                        .accessibilityLabel(game.name)
                } else {
                    Text(Theme.displayName(preferred.program))
                        .font(.system(.title, design: .serif, weight: .semibold))
                        .foregroundStyle(Theme.pale)
                        .shadow(color: .black.opacity(0.4), radius: 4)
                }
                Spacer()
                if running { RunningBadge() }
            }
            .padding(14)
        }
        .frame(height: 170)
        .clipped()
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if running {
                Button {
                    Task { await library.stop(game) }
                } label: {
                    Label("Ukončit", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            } else {
                Button {
                    Task { await library.launch(preferred) }
                } label: {
                    Label("Spustit", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                Button("S ukazatelem výkonu", systemImage: "gauge.with.dots.needle.67percent") {
                    Task { await library.launch(preferred, hud: true) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .help("Spustit s ukazatelem výkonu (FPS, GPU)")
            }
        }
        .controlSize(.extraLarge)
    }

    /// Which prefix the game starts in by default; changes stick.
    private var modes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Výchozí režim").font(.headline)
            Picker("Výchozí režim", selection: Binding(
                get: { preferred.id },
                set: { id in game.variants.first { $0.id == id }.map(library.makeDefault) })) {
                ForEach(game.variants) { variant in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Theme.shortVariantName(variant))
                        Text(variant.prefix.name).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(variant.id)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Jak běží").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Prefix", preferred.prefix.name)
                row("Wine", Theme.wineName(preferred.prefix.wine))
                row("Grafika", Theme.gfxName(preferred.prefix.gfx))
                if preferred.prefix.wine != "gptk" {
                    row("Vulkan", Theme.vulkanName(preferred.prefix.vulkan))
                }
                if let appid = preferred.program.appid {
                    row("Steam", "App \(appid)")
                }
                if let graphics = preferred.program.graphics, !graphics.isEmpty {
                    row("Hra používá", graphics.map(Theme.graphicsName).joined(separator: ", "))
                }
            }
            .font(.callout)
        }
    }

    /// What the graphics the game uses mean for running it here.
    @ViewBuilder
    private var compatibilityNote: some View {
        if let graphics = preferred.program.graphics, !graphics.isEmpty {
            switch Compatibility(graphics: graphics, prefix: preferred.prefix) {
            case .d3d12Only:
                Note(symbol: "exclamationmark.triangle.fill", tint: .orange,
                     text: "Hra umí jen DirectX 12, který tady zatím nefunguje, takže se nejspíš nespustí.")
            case .prefersD3D12:
                Note(symbol: "info.circle", tint: .secondary,
                     text: "Hra umí DirectX 12 i starší verzi. Kdyby se nespustila, přepni ji v nastavení nebo ve spouštěči na DirectX 11 (ve Steamu často parametr -dx11).")
            case .vulkanOnMoltenVK:
                Note(symbol: "info.circle", tint: .secondary,
                     text: "Hra používá Vulkan. Kdyby nefungovala, přepni v prefixu ovladač Vulkanu na KosmicKrisp.")
            case .fine:
                EmptyView()
            }
        }
    }

    /// DXMT draws D3D10/11 games, and its upscaling and frame pacing are set per game.
    private var showsPicture: Bool {
        let program = preferred.program
        let steamClient = program.kind == .default && program.exe.lowercased().hasSuffix("\\steam.exe")
        return preferred.prefix.gfx == "dxmt" && !steamClient
            && (program.graphics.map { $0.isEmpty || !Set($0).isDisjoint(with: ["d3d11", "d3d10"]) } ?? true)
    }

    private var picture: some View {
        let settings = preferred.program.settings ?? GameSettings()
        let item = preferred
        return VStack(alignment: .leading, spacing: 8) {
            Text("Obraz").font(.headline)
            Picker("MetalFX", selection: Binding(
                get: { settings.metalfx ?? 0 },
                set: { factor in Task { await library.setGame(item, "metalfx", factor == 0 ? "off" : String(factor)) } })) {
                Text("Vypnuto").tag(0.0)
                Text("1,5×").tag(1.5)
                Text("2×").tag(2.0)
            }
            Picker("Limit snímků", selection: Binding(
                get: { settings.fps ?? 0 },
                set: { fps in Task { await library.setGame(item, "fps", fps == 0 ? "off" : String(fps)) } })) {
                Text("Bez limitu").tag(0)
                Text("40 fps").tag(40)
                Text("60 fps").tag(60)
                Text("120 fps").tag(120)
            }
            Text("MetalFX zvětší obraz hry Applovým upscalingem: s nižším rozlišením nastaveným ve hře tak dostaneš víc snímků. S limitem řídí tempo snímků Metal, takže jdou rovnoměrněji; hodnota by měla dělit obnovovací frekvenci displeje. Změny platí od dalšího spuštění hry, zapnutí nebo vypnutí MetalFX až po restartu Steamu (prefixu).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let folder = preferred.program.folderURL(in: preferred.prefix) {
                Button("Otevřít složku hry", systemImage: "folder") { NSWorkspace.shared.open(folder) }
            }
            if let log = preferred.program.log, FileManager.default.fileExists(atPath: log) {
                Button("Zobrazit výpis", systemImage: "doc.text.magnifyingglass") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: log))
                }
                .help("Co program naposledy vypsal, užitečné, když se nespustí")
            }
            Button("Zobrazit prefix", systemImage: "shippingbox") { showPrefix(preferred.prefix) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
    }
}

/// A short remark with an icon, such as a warning about the game.
struct Note: View {
    var symbol: String
    var tint: Color
    var text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 8))
    }
}

// MARK: - Artwork

/// Finds a game's artwork in Steam's local cache (appcache/librarycache/<appid>).
enum CoverArt {
    enum Kind: String {
        case cover, hero, logo
    }

    @MainActor private static var cache: [String: NSImage?] = [:]

    @MainActor
    static func image(_ kind: Kind, in directory: String?) async -> NSImage? {
        guard let directory else { return nil }
        let key = "\(kind.rawValue):\(directory)"
        if let cached = cache[key] { return cached }
        let image = await Task.detached { find(kind, in: URL(fileURLWithPath: directory)) }.value
        cache[key] = image
        return image
    }

    /// Steam keeps most images in folders named by hash: the cover is
    /// library_capsule.jpg (else the largest portrait image), the wide one
    /// library_hero.jpg, and logo.png sits at the top.
    private nonisolated static func find(_ kind: Kind, in directory: URL) -> NSImage? {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        func named(_ name: String) -> NSImage? {
            files.first { $0.lastPathComponent == name }.flatMap(NSImage.init(contentsOf:))
        }
        switch kind {
        case .hero: return named("library_hero.jpg")
        case .logo: return named("logo.png")
        case .cover:
            if let capsule = named("library_capsule.jpg") { return capsule }
            return files.filter { $0.pathExtension.lowercased() == "jpg" }
                .compactMap { NSImage(contentsOf: $0) }
                .filter { $0.size.height > $0.size.width }
                .max { $0.size.height < $1.size.height }
        }
    }
}
