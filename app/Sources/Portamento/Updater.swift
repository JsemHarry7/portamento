import AppKit
import CryptoKit
import Foundation
import Observation

/// A Portamento release on the project's GitHub releases: tag app-<version> with
/// Portamento-<version>.zip, as .github/workflows/app.yml makes them.
struct AppRelease: Equatable, Sendable {
    var version: String
    var notes: String
    var zip: URL
    var size: Int64
    /// The zip's SHA-256 as GitHub reports it, when it does.
    var sha256: String?
    var page: URL

    fileprivate init?(_ release: GitHubRelease) {
        guard !release.draft, !release.prerelease, release.tag_name.hasPrefix("app-") else { return nil }
        let version = String(release.tag_name.dropFirst(4))
        guard let asset = release.assets.first(where: { $0.name == "Portamento-\(version).zip" }),
              let zip = URL(string: asset.browser_download_url), let page = URL(string: release.html_url)
        else { return nil }
        self.version = version
        notes = release.body ?? ""
        self.zip = zip
        size = asset.size
        sha256 = asset.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        self.page = page
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        var name: String
        var browser_download_url: String
        var size: Int64
        var digest: String?
    }
    var tag_name: String
    var html_url: String
    var body: String?
    var draft: Bool
    var prerelease: Bool
    var assets: [Asset]
}

/// Finds newer Portamento releases and puts one in place of the running app: it
/// downloads the zip, checks it, swaps the bundle and opens the new one.
@MainActor @Observable
final class AppUpdater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading(received: Int64, total: Int64)
        case installing
        case failed(String)
    }

    private(set) var state = State.idle
    /// The newest release, once a check found one.
    private(set) var release: AppRelease?
    /// The version the banner was closed for, until the next start.
    var dismissed: String?
    /// Set on the first start after an update: the version it came from.
    private(set) var updatedFrom: String?

    static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// Release builds look for updates by themselves; builds from a checkout only when asked.
    let checksAutomatically = Bundle.main.object(forInfoDictionaryKey: "PortamentoChecksForUpdates") as? Bool ?? false
    private let repository = Bundle.main.object(forInfoDictionaryKey: "PortamentoRepository") as? String
        ?? "JsemHarry7/portamento"
    private static let updatedFromKey = "updatedFrom"

    init() {
        updatedFrom = UserDefaults.standard.string(forKey: Self.updatedFromKey)
        UserDefaults.standard.removeObject(forKey: Self.updatedFromKey)
    }

    var isBusy: Bool {
        switch state {
        case .downloading, .installing: true
        default: false
        }
    }

    /// Whether the library shows the banner: a release to install, or one installing.
    var showsBanner: Bool {
        guard let release else { return false }
        switch state {
        case .available: return dismissed != release.version
        case .downloading, .installing, .failed: return true
        default: return false
        }
    }

    /// Checks on start and then every few hours, in release builds.
    func checkPeriodically() async {
        guard checksAutomatically else { return }
        try? await Task.sleep(for: .seconds(3))
        while !Task.isCancelled {
            await check(quietly: true)
            try? await Task.sleep(for: .seconds(6 * 3600))
        }
    }

    /// Looks for a newer release. Quietly, a failure leaves things as they were.
    func check(quietly: Bool = false) async {
        guard !isBusy else { return }
        if !quietly { state = .checking }
        do {
            var request = URLRequest(url: releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Portamento/\(Self.current)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.server }
            let newest = try JSONDecoder().decode([GitHubRelease].self, from: data)
                .compactMap(AppRelease.init)
                .filter { Self.isNewer($0.version, than: Self.current) }
                .max { Self.isNewer($1.version, than: $0.version) }
            release = newest
            state = newest == nil ? .upToDate : .available
        } catch {
            if !quietly {
                state = .failed(String(localized: "Nepodařilo se zjistit, jestli je nová verze. \(error.localizedDescription)"))
            }
        }
    }

    /// Downloads the release, swaps it in for this app and starts it.
    func install() async {
        guard let release, !isBusy else { return }
        state = .downloading(received: 0, total: release.size)
        do {
            let app = Bundle.main.bundleURL
            if app.path.contains("/AppTranslocation/") { throw UpdateError.translocated }
            let files = FileManager.default
            // next to the app, so the new one moves into place on the same volume
            let work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
            defer { try? files.removeItem(at: work) }
            let zip = work.appending(path: "Portamento.zip")
            try await Task.detached {
                try await Self.download(release, to: zip) { received, total in
                    Task { @MainActor in
                        if case .downloading = self.state { self.state = .downloading(received: received, total: total) }
                    }
                }
            }.value

            state = .installing
            let unpacked = work.appending(path: "unpacked")
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
            let new = unpacked.appending(path: "Portamento.app")
            let info = NSDictionary(contentsOf: new.appending(path: "Contents/Info.plist"))
            guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                  info?["CFBundleShortVersionString"] as? String == release.version
            else { throw UpdateError.notPortamento }
            try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", new.path])
            do {
                _ = try files.replaceItemAt(app, withItemAt: new)
            } catch {
                throw UpdateError.cantReplace(app.deletingLastPathComponent().path)
            }
            UserDefaults.standard.set(Self.current, forKey: Self.updatedFromKey)
            relaunch(app)
        } catch {
            state = .failed((error as? UpdateError)?.message ?? error.localizedDescription)
        }
    }

    func openReleasePage() {
        if let page = release?.page { NSWorkspace.shared.open(page) }
    }

    /// After a failed check or install, back to what the banner showed before.
    func reset() {
        state = release == nil ? .idle : .available
    }

    private var releasesURL: URL {
        if let custom = ProcessInfo.processInfo.environment["PORTAMENTO_RELEASES_URL"], let url = URL(string: custom) {
            return url
        }
        return URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!
    }

    /// Off the main thread: the bytes come one at a time.
    private nonisolated static func download(_ release: AppRelease, to file: URL,
                                             progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: release.zip)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.server }
        let total = response.expectedContentLength > 0 ? response.expectedContentLength : release.size
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw UpdateError.server }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var hash = SHA256()
        var chunk = Data()
        chunk.reserveCapacity(1 << 18)
        var received: Int64 = 0
        func flush() throws {
            try handle.write(contentsOf: chunk)
            hash.update(data: chunk)
            received += Int64(chunk.count)
            chunk.removeAll(keepingCapacity: true)
            progress(received, total)
        }
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= 1 << 18 { try flush() }
        }
        try flush()
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        if let expected = release.sha256, expected.lowercased() != digest { throw UpdateError.corrupt }
    }

    /// Opens the app at `app` once this process has quit.
    private func relaunch(_ app: URL) {
        let wait = "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\""
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", wait, app.path]
        try? shell.run()
        NSApp.terminate(nil)
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 { throw UpdateError.notPortamento }
        }.value
    }

    /// Compares dotted versions number by number (0.10 is newer than 0.9).
    static func isNewer(_ version: String, than other: String) -> Bool {
        func numbers(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = numbers(version), b = numbers(other)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

enum UpdateError: Error {
    case server, corrupt, notPortamento, translocated
    case cantReplace(String)

    var message: String {
        switch self {
        case .server: String(localized: "GitHub teď vydání nedal, zkus to později.")
        case .corrupt: String(localized: "Stažený soubor je poškozený, zkus to znovu.")
        case .notPortamento: String(localized: "Stažený soubor není platné Portamento.")
        case .translocated: String(localized: "macOS spouští Portamento z dočasné kopie. Přesuň ho do složky Aplikace, otevři ho znovu a aktualizuj.")
        case .cantReplace(let folder): String(localized: "Portamento nemůže přepsat sám sebe ve složce \(folder). Stáhni novou verzi ze stránky vydání.")
        }
    }
}
