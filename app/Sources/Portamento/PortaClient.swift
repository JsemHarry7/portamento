import Foundation

/// Runs the `porta` command line tool, which does all the actual work.
struct PortaClient {
    var script: URL

    /// PORTA_PATH if set, else the `porta` linked into a bin directory (README's install
    /// step), else a checkout in ~/Developer/porting.
    static let `default` = PortaClient(script: {
        let env = ProcessInfo.processInfo.environment
        if let path = env["PORTA_PATH"] {
            return URL(fileURLWithPath: path)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = ["/opt/homebrew/bin/porta", "/usr/local/bin/porta", home.appending(path: ".local/bin/porta").path]
        if let found = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: found).resolvingSymlinksInPath()
        }
        return home.appending(path: "Developer/porting/porta")
    }())

    /// Support data Portamento keeps under Application Support (PORTA_HOME moves it, as for porta).
    static let home: URL = {
        if let path = ProcessInfo.processInfo.environment["PORTA_HOME"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Portamento")
    }()

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    @discardableResult
    func run(_ arguments: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path] + arguments
        // apps started from Finder don't get the shell's PATH
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    continuation.resume(throwing: Failure(message: message.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "porta: ", with: "")))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func inventory() async throws -> Inventory {
        try JSONDecoder().decode(Inventory.self, from: try await run(["list", "--json"]))
    }

    func launch(_ item: LibraryItem, hud: Bool = false) async throws {
        try await run(["run"] + (hud ? ["--hud"] : []) + [item.prefix.name, item.program.exe] + item.program.args)
    }

    func kill(_ prefix: Prefix) async throws {
        try await run(["kill", prefix.name])
    }

    func set(_ prefix: Prefix, _ key: String, _ value: String) async throws {
        try await run(["set", prefix.name, key, value])
    }

    func addProgram(_ prefix: Prefix, name: String, exe: String) async throws {
        try await run(["program", "add", prefix.name, name, exe])
    }

    func create(name: String, wine: String, gfx: String) async throws {
        try await run(["create", name, "--wine", wine, "--gfx", gfx])
    }

    func selftest() async throws {
        try await run(["selftest"])
    }

    /// The newest `porta selftest` report, if there is one.
    func latestSelftest() -> (date: Date, results: [SelftestResult])? {
        let logs = Self.home.appending(path: "logs")
        let reports = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.lastPathComponent.hasPrefix("selftest-") && $0.pathExtension == "json" } ?? []
        let dated = reports.compactMap { url -> (URL, Date)? in
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
            return (url, date)
        }
        guard let (url, date) = dated.max(by: { $0.1 < $1.1 }),
              let data = try? Data(contentsOf: url),
              let results = try? JSONDecoder().decode([SelftestResult].self, from: data) else { return nil }
        return (date, results)
    }
}
