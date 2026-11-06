import Foundation
import Observation

/// App state: what porta knows about, and the actions the UI can take.
@MainActor @Observable
final class Library {
    private(set) var inventory = Inventory.empty
    private(set) var selftest: (date: Date, results: [SelftestResult])?
    private(set) var isTesting = false
    /// A long porta command running now (setup, an install), shown with its progress.
    private(set) var activity: Activity?
    /// Requirements porta can't install itself; checked when setup is needed.
    private(set) var requirements: [PortaClient.Requirement] = []
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

    /// Runtimes `porta setup` still has to fetch. Only meaningful once loaded.
    var needsSetup: Bool { loaded && !inventory.setup.missing.isEmpty }
    /// Nothing installed yet: the app opens on the welcome screen.
    var needsFirstSetup: Bool { needsSetup && !inventory.wines.values.contains(true) }
    private(set) var loaded = false

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
        loaded = true
        selftest = client.latestSelftest()
        if needsSetup { requirements = await PortaClient.missingRequirements() }
    }

    func checkRequirements() async {
        requirements = await PortaClient.missingRequirements()
    }

    /// Downloads and unpacks everything porta needs.
    func runSetup() async {
        await track("Příprava Portamenta") { output in
            try await self.client.setup(output: output)
        }
        await reload()
    }

    /// Installs Steam or runs an installer in a prefix, creating the prefix first if
    /// it doesn't exist. Returns what was added, nil if it failed.
    func install(_ source: InstallSource, into name: String, wine: String, gfx: String) async -> InstallReport? {
        var report: InstallReport?
        await track(source.title) { output in
            if self.prefix(named: name) == nil {
                output("Vytvářím prefix \(name)")
                try await self.client.create(name: name, wine: wine, gfx: gfx)
            }
            report = try await self.client.install(into: name, source.argument, output: output)
        }
        await reload()
        return report
    }

    func delete(_ prefix: Prefix) async {
        await perform { try await self.client.delete(prefix) }
        await reload()
    }

    func openTool(_ tool: String, in prefix: Prefix) async {
        await perform { try await self.client.wineTool(prefix, tool) }
    }

    /// Runs a long command as the current activity, collecting its output.
    private func track(_ title: String, _ work: @escaping (@escaping @Sendable (String) -> Void) async throws -> Void) async {
        let activity = Activity(title: title)
        self.activity = activity
        let output: @Sendable (String) -> Void = { line in
            Task { @MainActor in activity.add(line) }
        }
        do {
            try await work(output)
            activity.finish(error: nil)
        } catch {
            activity.finish(error: error.localizedDescription)
        }
    }

    func dismissActivity() {
        if activity?.isRunning == false { activity = nil }
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

    func perform(_ action: () async throws -> Void) async {
        do {
            try await action()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// What to install into a prefix.
enum InstallSource: Hashable {
    case steam
    /// An installer file; nil until one is picked.
    case installer(URL?)

    var argument: String {
        switch self {
        case .steam: "steam"
        case .installer(let url): url?.path ?? ""
        }
    }

    var title: String {
        switch self {
        case .steam: "Instalace Steamu"
        case .installer(let url): "Instalace \(url?.lastPathComponent ?? "hry")"
        }
    }
}

/// A long porta command and what it has printed so far.
@MainActor @Observable
final class Activity {
    let title: String
    private(set) var lines: [String] = []
    /// The newest step porta reported, for the headline.
    private(set) var step = "Spouštím…"
    /// 0...1 while curl reports a download, else nil.
    private(set) var progress: Double?
    private(set) var isRunning = true
    private(set) var error: String?

    init(title: String) {
        self.title = title
    }

    func add(_ line: String) {
        let line = line.trimmingCharacters(in: .whitespaces)
        // curl -# draws "###...   42.0%"
        if let match = line.firstMatch(of: /([0-9]+(?:\.[0-9])?)%$/), let percent = Double(match.1) {
            progress = percent / 100
            return
        }
        if line.allSatisfy({ $0 == "#" || $0 == " " }) { return }
        lines.append(line)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        step = Self.describe(line)
        if !line.hasPrefix("downloading") { progress = nil }
    }

    func finish(error: String?) {
        isRunning = false
        self.error = error
        progress = nil
        step = error == nil ? "Hotovo" : "Nepovedlo se"
    }

    /// porta's progress lines, in Czech.
    private static func describe(_ line: String) -> String {
        let rules: [(String, String)] = [
            ("downloading ", "Stahuji "), ("installed ", "Nainstalováno: "), ("building ", "Sestavuji "),
            ("built runtime ", "Připraveno: "), ("updated ", "Aktualizováno: "), ("installing Rosetta", "Instaluji Rosettu"),
            ("installing Steam", "Instaluji Steam"), ("running ", "Běží instalátor "), ("ready:", "Hotovo"),
        ]
        for (prefix, czech) in rules where line.hasPrefix(prefix) {
            var rest = String(line.dropFirst(prefix.count))
            if prefix == "running " { rest = rest.components(separatedBy: ",").first ?? rest }
            if prefix == "building " { rest = rest.replacingOccurrences(of: " from source, this takes a while", with: " ze zdrojáků (trvá to)") }
            return czech + rest
        }
        return line
    }
}
