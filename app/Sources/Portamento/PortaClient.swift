import Foundation

/// Runs the `porta` command line tool, which does all the actual work.
struct PortaClient {
    var script: URL

    /// PORTA_PATH if set, else the `porta` linked into a bin directory (README's install
    /// step, so a checkout wins while developing), else the copy inside the app.
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
        if let bundled = Bundle.main.resourceURL?.appending(path: "porta/porta"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
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

    private func process(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path] + arguments
        // apps started from Finder don't get the shell's PATH
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        process.environment = env
        return process
    }

    @discardableResult
    func run(_ arguments: [String]) async throws -> Data {
        let process = process(arguments)
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
                    continuation.resume(throwing: Failure(message: Self.lastError(message)))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Runs a long command, handing each line of its output (stdout and stderr, where
    /// curl draws its progress bar with carriage returns) to `output` as it arrives.
    /// Returns everything it printed on stdout.
    @discardableResult
    func stream(_ arguments: [String], output: @escaping @Sendable (String) -> Void) async throws -> String {
        let process = process(arguments)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let collected = Collected()

        func forward(_ pipe: Pipe, keep: Bool) {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                let text = String(decoding: data, as: UTF8.self)
                collected.add(text, stdout: keep)
                for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) where !line.isEmpty {
                    output(String(line))
                }
            }
        }
        forward(out, keep: true)
        forward(err, keep: false)

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                // let the handlers drain what's left in the pipes
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                collected.add(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), stdout: true)
                collected.add(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), stdout: false)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: collected.stdout)
                } else {
                    continuation.resume(throwing: Failure(message: Self.lastError(collected.stderr)))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// porta reports failures as "porta: <message>" on its last line; Python tracebacks end with the error too.
    private static func lastError(_ output: String) -> String {
        let lines = output.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let line = lines.last(where: { $0.hasPrefix("porta: ") }) ?? lines.last ?? "porta skončil s chybou"
        return line.replacingOccurrences(of: "porta: ", with: "")
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

    func delete(_ prefix: Prefix) async throws {
        try await run(["delete", prefix.name])
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

    func setup(output: @escaping @Sendable (String) -> Void) async throws {
        try await stream(["setup"], output: output)
    }

    /// Installs Steam ("steam") or runs an installer, and reports what it added.
    func install(into prefix: String, _ what: String, output: @escaping @Sendable (String) -> Void) async throws -> InstallReport {
        let printed = try await stream(["install", prefix, what, "--json"], output: output)
        guard let json = printed.split(separator: "\n").last(where: { $0.hasPrefix("{") }) else {
            throw Failure(message: "porta install nic neohlásil")
        }
        return try JSONDecoder().decode(InstallReport.self, from: Data(json.utf8))
    }

    /// Opens one of Wine's own programs (winecfg, regedit, taskmgr) in a prefix.
    func wineTool(_ prefix: Prefix, _ tool: String) async throws {
        try await run(["wine", prefix.name, tool])
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

    /// What porta needs from the Mac before `porta setup` can run, that it can't install itself.
    static func missingRequirements() async -> [Requirement] {
        await Task.detached {
            var missing: [Requirement] = []
            // python3 comes with the Command Line Tools (or Homebrew); /usr/bin/python3 is only a stub without them
            let pythons = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                           "/Library/Developer/CommandLineTools/usr/bin/python3",
                           "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"]
            if !pythons.contains(where: FileManager.default.isExecutableFile(atPath:)) {
                missing.append(.python)
            }
            if !succeeds("/usr/bin/arch", ["-x86_64", "/usr/bin/true"]) {
                missing.append(.rosetta)
            }
            return missing
        }.value
    }

    enum Requirement: Hashable {
        case python, rosetta
    }

    private static func succeeds(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// Output gathered from a streamed command's pipes, on whatever threads they deliver it.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var out = "", err = ""

    func add(_ text: String, stdout: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if stdout { out += text } else { err += text }
    }

    var stdout: String {
        lock.lock()
        defer { lock.unlock() }
        return out
    }

    var stderr: String {
        lock.lock()
        defer { lock.unlock() }
        return err
    }
}
