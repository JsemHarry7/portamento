import Foundation
import Observation

/// App state: what porta knows about, and the actions the UI can take.
@MainActor @Observable
final class Library {
    private(set) var inventory = Inventory.empty
    private(set) var selftest: (date: Date, results: [SelftestResult])?
    private(set) var isTesting = false
    var error: String?
    /// Game id -> the variant (LibraryItem id) the user made the default.
    private var chosenDefaults: [String: String]

    private let client: PortaClient
    private static let defaultsKey = "defaultVariants"

    init(client: PortaClient = .default) {
        self.client = client
        chosenDefaults = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    var prefixes: [Prefix] { inventory.prefixes.filter { !$0.isInternal } }

    /// Everything that can be launched, across prefixes.
    var items: [LibraryItem] {
        prefixes.flatMap { prefix in prefix.programs.map { LibraryItem(program: $0, prefix: prefix) } }
    }

    /// The library's tiles: one per game, however many prefixes have it.
    var games: [GameEntry] {
        Dictionary(grouping: items, by: \.gameID)
            .map { id, items in GameEntry(id: id, variants: items.sorted { $0.rank > $1.rank }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The variant to launch by default: the user's choice if it still exists, else the best one.
    func defaultVariant(of game: GameEntry) -> LibraryItem {
        game.variants.first { $0.id == chosenDefaults[game.id] } ?? game.variants[0]
    }

    func makeDefault(_ item: LibraryItem) {
        chosenDefaults[item.gameID] = item.id
        UserDefaults.standard.set(chosenDefaults, forKey: Self.defaultsKey)
    }

    /// The Wine processes running now. Wine names each process after its Windows
    /// command line, so in ps they read "C:\...\game.exe ...".
    private(set) var processes: [WineProcess] = []
    /// The variant last launched from here, per game: ps can't tell which prefix a process is in.
    private var launched: [String: LibraryItem] = [:]

    func refreshRunning() async {
        let output = await Task.detached { () -> String in
            let ps = Process(), out = Pipe()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-axo", "pid=,command="]
            ps.standardOutput = out
            guard (try? ps.run()) != nil else { return "" }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            ps.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
        let found = output.split(separator: "\n").compactMap(WineProcess.init)
        if found != processes { processes = found }
    }

    func processes(of game: GameEntry) -> [WineProcess] {
        let keys = Set(game.variants.flatMap(\.processKeys))
        return processes.filter { process in keys.contains { process.command.contains($0) } }
    }

    func isRunning(_ game: GameEntry) -> Bool { !processes(of: game).isEmpty }

    var runningCount: Int { games.count(where: isRunning) }

    /// The variant that is running: the one started from here if known, else the default.
    func runningVariant(of game: GameEntry) -> LibraryItem {
        launched[game.id] ?? defaultVariant(of: game)
    }

    /// Ends a game. A prefix's own program (Steam, say) takes its whole prefix down
    /// with it; a game only its own processes, so Steam stays up.
    func stop(_ game: GameEntry) async {
        let variant = runningVariant(of: game)
        if variant.program.kind == .default {
            await kill(variant.prefix)
        } else {
            for process in processes(of: game) { Darwin.kill(process.pid, SIGTERM) }
        }
        try? await Task.sleep(for: .seconds(1))
        await refreshRunning()
    }

    func prefix(named name: String) -> Prefix? {
        inventory.prefixes.first { $0.name == name }
    }

    func reload() async {
        await perform { self.inventory = try await self.client.inventory() }
        selftest = client.latestSelftest()
    }

    func launch(_ item: LibraryItem, hud: Bool = false) async {
        launched[item.gameID] = item
        await perform { try await self.client.launch(item, hud: hud) }
    }

    func kill(_ prefix: Prefix) async {
        await perform { try await self.client.kill(prefix) }
    }

    func set(_ prefix: Prefix, _ key: String, _ value: String) async {
        await perform { try await self.client.set(prefix, key, value) }
        await reload()
    }

    func addProgram(to prefix: Prefix, name: String, exe: URL) async {
        await perform { try await self.client.addProgram(prefix, name: name, exe: exe.path) }
        await reload()
    }

    func create(name: String, wine: String, gfx: String) async {
        await perform { try await self.client.create(name: name, wine: wine, gfx: gfx) }
        await reload()
    }

    func runSelftest() async {
        isTesting = true
        defer { isTesting = false }
        await perform { try await self.client.selftest() }
        selftest = client.latestSelftest()
    }

    private func perform(_ action: () async throws -> Void) async {
        do {
            try await action()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
