import SwiftUI

/// Above the library: a new Portamento to install, its download, or that one just was.
struct UpdateBanner: View {
    @Environment(AppUpdater.self) private var updater
    @EnvironmentObject private var content: ContentState

    var body: some View {
        if updater.showsBanner, let release = updater.release {
            banner(release)
        } else if let from = updater.updatedFrom, updater.dismissed != AppUpdater.current {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Portamento \(AppUpdater.current) je nainstalované").font(.headline)
                    Text("Předtím \(from). Hry a prefixy zůstaly, jak byly.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                close { updater.dismissed = AppUpdater.current }
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }

    private func banner(_ release: AppRelease) -> some View {
        HStack(spacing: 10) {
            symbol
            VStack(alignment: .leading, spacing: 4) {
                Text(title(release)).font(.headline)
                detail(release)
            }
            Spacer()
            actions
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    @ViewBuilder
    private var symbol: some View {
        switch updater.state {
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
        case .downloading, .installing:
            ProgressView().controlSize(.small).frame(width: 24)
        default:
            Image(systemName: "sparkles").font(.title2).foregroundStyle(Theme.accent)
        }
    }

    private func title(_ release: AppRelease) -> String {
        switch updater.state {
        case .downloading: String(localized: "Stahuji Portamento \(release.version)")
        case .installing: String(localized: "Instaluji Portamento \(release.version)")
        case .failed: String(localized: "Aktualizace se nepovedla")
        default: String(localized: "Nové Portamento \(release.version)")
        }
    }

    @ViewBuilder
    private func detail(_ release: AppRelease) -> some View {
        switch updater.state {
        case .downloading(let received, let total):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: total > 0 ? Double(received) / Double(total) : 0)
                Text("\(Theme.bytes(received)) z \(Theme.bytes(total))").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 320)
        case .installing:
            Text("Za chvíli se Portamento samo otevře znovu. Běžící hry poběží dál.")
                .font(.callout).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        default:
            Text("Máš \(AppUpdater.current). Hry a prefixy zůstanou, jak jsou, a běžící hry poběží dál.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch updater.state {
        case .downloading, .installing:
            EmptyView()
        case .failed:
            Button("Stránka vydání") { updater.openReleasePage() }.buttonStyle(.glass)
            Button("Zkusit znovu") { Task { await updater.install() } }.buttonStyle(.glassProminent)
            close { updater.reset(); updater.dismissed = updater.release?.version }
        default:
            Button("Co je nového") { content.showingUpdate = true }.buttonStyle(.glass)
            Button("Aktualizovat") { Task { await updater.install() } }.buttonStyle(.glassProminent)
            close { updater.dismissed = updater.release?.version }
        }
    }

    private func close(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Skrýt do příštího spuštění")
    }
}

/// Portamento › Check for Updates…, and the release notes from the banner.
struct UpdateSheet: View {
    @Environment(AppUpdater.self) private var updater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch updater.state {
            case .checking:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Hledám novou verzi…")
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            case .upToDate, .idle:
                message(symbol: "checkmark.circle.fill", tint: .green, title: "Máš nejnovější Portamento",
                        text: String(localized: "Verze \(AppUpdater.current)."))
            case .failed(let error):
                message(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "Aktualizace se nepovedla", text: error)
            case .available, .downloading, .installing:
                if let release = updater.release { notes(release) }
            }
            HStack {
                Spacer()
                switch updater.state {
                case .available:
                    Button("Později") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Aktualizovat a restartovat") {
                        dismiss()
                        Task { await updater.install() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                case .failed:
                    Button("Zavřít") {
                        updater.reset()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Zkusit znovu") { Task { await updater.check() } }
                        .keyboardShortcut(.defaultAction)
                case .checking:
                    Button("Zavřít") { dismiss() }.keyboardShortcut(.cancelAction)
                default:
                    Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func message(symbol: String, tint: Color, title: LocalizedStringKey, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func notes(_ release: AppRelease) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Portamento \(release.version)").font(.title2.bold())
                Text("máš \(AppUpdater.current)").foregroundStyle(.secondary)
                Spacer()
                Text(Theme.bytes(release.size)).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(Self.markdown(release.notes))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 120, maxHeight: 320)
            Text("Hry, prefixy a nastavení zůstanou, jak jsou, a běžící hry poběží dál. Když nová verze potřebuje novější Wine nebo grafické ovladače, stáhne je hned po restartu.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// GitHub's Markdown, near enough: inline styles, headings in bold, lists with bullets.
    private static func markdown(_ notes: String) -> AttributedString {
        let lines = notes.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.drop { $0 == " " }
                if let heading = trimmed.firstMatch(of: /^#{1,6} +(.*)$/) { return "**\(heading.1)**" }
                if let item = trimmed.firstMatch(of: /^[-*+] +(.*)$/) {
                    return String(repeating: " ", count: line.count - trimmed.count) + "• " + item.1
                }
                return String(line)
            }
        let text = notes.isEmpty ? String(localized: "Vydání nemá popis.") : lines.joined(separator: "\n")
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
