import Foundation

/// What `porta list --json` reports.
struct Inventory: Decodable {
    var prefixes: [Prefix]
    var wines: [String: Bool]
    var backends: [String: Bool]
    var vulkan: [String: Bool]
    var defaults: Defaults
    var setup: Setup

    struct Defaults: Decodable {
        var wine: String
        var gfx: String
    }

    /// What `porta setup` still has to download or build.
    struct Setup: Decodable {
        var missing: [String]
    }

    static let empty = Inventory(prefixes: [], wines: [:], backends: [:], vulkan: [:],
                                 defaults: .init(wine: "cx", gfx: "dxmt"), setup: .init(missing: []))
}

struct Prefix: Decodable, Identifiable, Hashable {
    var name: String
    var wine: String
    var gfx: String
    var vulkan: String
    var args: [String]
    var env: [String: String]
    var path: String
    var programs: [Program]

    var id: String { name }
    /// Scratch prefixes `porta selftest` makes for itself.
    var isInternal: Bool { name.hasPrefix("selftest-") }
    var driveC: URL { URL(fileURLWithPath: path).appending(path: "drive_c") }
}

struct Program: Decodable, Identifiable, Hashable {
    var name: String
    var kind: Kind
    var exe: String
    var args: [String]
    var appid: String?
    var art: String?
    var folder: String?
    /// Where `porta run` writes the program's output.
    var log: String?

    enum Kind: String, Decodable {
        case `default`, steam, custom
    }

    var id: String { "\(kind.rawValue)/\(appid ?? name)" }
}

/// A program as it sits in the library, with the prefix it runs in.
struct LibraryItem: Identifiable, Hashable {
    var program: Program
    var prefix: Prefix

    var id: String { "\(prefix.name)/\(program.id)" }

    /// Steam games are the same game in every prefix; anything else is matched by name.
    var gameID: String {
        if let appid = program.appid { return "steam/\(appid)" }
        return "name/\(program.name.lowercased())"
    }

    /// How good a way of running the game this is, for picking a default:
    /// CrossOver's Wine (msync) over staging over the old D3DMetal Wine, DXMT first.
    var rank: Int {
        let wine = ["cx": 30, "staging": 20, "gptk": 10][prefix.wine] ?? 0
        let gfx = ["dxmt": 3, "dxvk": 2, "d3dmetal": 2, "wined3d": 1][prefix.gfx] ?? 0
        return wine + gfx
    }

    /// Lowercased pieces of a Windows command line that mean this program is running:
    /// anything in a Steam game's folder, or the program's own exe.
    var processKeys: [String] {
        if let folder = program.folder {
            return ["\\steamapps\\common\\" + (folder as NSString).lastPathComponent.lowercased() + "\\"]
        }
        return ["\\" + (program.exe.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent.lowercased()]
    }
}

/// One tile in the library: a game, and every prefix that can run it.
struct GameEntry: Identifiable {
    var id: String
    var variants: [LibraryItem]  // best first

    var name: String { variants[0].program.name }
    var art: String? { variants.lazy.compactMap(\.program.art).first }
    var kind: Program.Kind { variants[0].program.kind }
}

extension Program {
    /// Where the program lives on the Mac: the game's folder, or the folder of its exe.
    func folderURL(in prefix: Prefix) -> URL? {
        if let folder { return URL(fileURLWithPath: folder) }
        guard exe.count > 2, exe.dropFirst().hasPrefix(":") else { return nil }
        let drive = exe.prefix(1).lowercased()
        let path = exe.dropFirst(3).replacingOccurrences(of: "\\", with: "/")
        return URL(fileURLWithPath: prefix.path).appending(path: "drive_\(drive)/\(path)").deletingLastPathComponent()
    }
}

/// A process running under Wine, from one line of `ps -axo pid=,command=`.
struct WineProcess: Equatable {
    var pid: Int32
    var command: String  // lowercased

    init?(_ line: Substring) {
        let line = line.drop { $0 == " " }
        guard let space = line.firstIndex(of: " "), let pid = Int32(line[..<space]) else { return nil }
        let command = line[line.index(after: space)...].lowercased()
        guard command.range(of: #"^"?[a-z]:\\"#, options: .regularExpression) != nil else { return nil }
        self.pid = pid
        self.command = command
    }
}

/// What `porta install --json` added to a prefix.
struct InstallReport: Decodable {
    var added: [Added]
    var exit: Int32

    struct Added: Decodable, Hashable {
        var name: String
        var exe: String
    }
}

/// One line of the newest `porta selftest` report.
struct SelftestResult: Decodable, Identifiable {
    var wine: String
    var gfx: String
    var vulkan: String
    var test: String
    var status: String
    var detail: String

    var id: String { "\(wine)/\(gfx)/\(vulkan)/\(test)" }
    var passed: Bool { status.hasPrefix("OK") }
}
