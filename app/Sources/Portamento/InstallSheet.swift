import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// What the install sheet opens with: a source and a prefix picked in advance, if any.
struct InstallRequest: Identifiable {
    var source: InstallSource?
    var prefix: String?
    let id = UUID()
}

final class InstallForm: ObservableObject {
    enum Kind: Hashable { case steam, installer }

    @Published var kind = Kind.steam
    @Published var installer: URL?
    /// The prefix to install into; "" for a new one.
    @Published var prefix = ""
    @Published var name = "steam"
    @Published var wine = "cx"
    @Published var gfx = "dxmt"
    @Published var nameEdited = false
    @Published var report: InstallReport?
    @Published var started = false

    var source: InstallSource? {
        switch kind {
        case .steam: .steam
        case .installer: installer.map { .installer($0) }
        }
    }

    /// Names of the prefixes that exist, so a suggested name doesn't clash.
    var taken: Set<String> = []

    /// A prefix name from what's being installed: "steam", or the installer's name
    /// without the words installers like to carry ("Setup_Game_v1.2.exe" -> "game"),
    /// numbered if a prefix has it already ("steam-2").
    func suggestName() {
        guard !nameEdited else { return }
        defer {
            let base = name
            var n = 2
            while taken.contains(name) {
                name = "\(base)-\(n)"
                n += 1
            }
        }
        switch kind {
        case .steam:
            name = "steam"
        case .installer:
            guard let installer else { return }
            let words = installer.deletingPathExtension().lastPathComponent.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .filter { !["setup", "install", "installer", "x64", "x86", "win64", "win32", "windows"].contains($0) }
                .filter { !$0.allSatisfy(\.isNumber) && !($0.first == "v" && $0.dropFirst().allSatisfy(\.isNumber)) }
            name = words.isEmpty ? "hra" : words.prefix(3).joined(separator: "-")
        }
    }
}

/// Installs Steam or a game's installer into a new or existing prefix.
struct InstallSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    var request: InstallRequest
    @StateObject private var form = InstallForm()

    private var existing: Bool { !form.prefix.isEmpty }
    private var nameTaken: Bool { !existing && library.prefix(named: form.name) != nil }
    private var running: Bool { form.started && library.activity?.isRunning == true }
    private var canInstall: Bool {
        form.source != nil && (existing || (!form.name.isEmpty && !form.name.contains("/") && !nameTaken))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Co instalovat", selection: $form.kind) {
                        Label("Steam", systemImage: "storefront").tag(InstallForm.Kind.steam)
                        Label("Hra ze souboru", systemImage: "shippingbox").tag(InstallForm.Kind.installer)
                    }
                    .pickerStyle(.segmented)
                    if form.kind == .installer {
                        LabeledContent("Instalátor") {
                            HStack {
                                Text(form.installer?.lastPathComponent ?? "Nevybráno")
                                    .foregroundStyle(form.installer == nil ? .secondary : .primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Button("Vybrat…") { chooseInstaller() }
                            }
                        }
                    }
                } footer: {
                    Text(form.kind == .steam
                         ? "Nainstaluje Steam pro Windows. Hry pak instaluješ ve Steamu a Portamento je samo najde."
                         : "Spustí instalátor hry pro Windows (.exe nebo .msi). Co vytvoří zástupce, přidá se do knihovny.")
                }

                Section("Kam") {
                    Picker("Prefix", selection: $form.prefix) {
                        Text("Nový prefix").tag("")
                        if !library.prefixes.isEmpty {
                            Divider()
                            ForEach(library.prefixes) { Text($0.name).tag($0.name) }
                        }
                    }
                    if !existing {
                        TextField("Název", text: Binding(get: { form.name },
                                                         set: { form.name = $0; form.nameEdited = true }))
                        if nameTaken {
                            Text("Prefix s tímhle názvem už existuje.").font(.callout).foregroundStyle(.red)
                        }
                        DisclosureGroup("Wine a grafika") {
                            Picker("Wine", selection: $form.wine) {
                                ForEach(library.inventory.wines.filter(\.value).keys.sorted(), id: \.self) {
                                    Text(Theme.wineName($0)).tag($0)
                                }
                            }
                            Picker("Grafická vrstva", selection: $form.gfx) {
                                ForEach(library.inventory.backends.keys.sorted()
                                    .filter { ($0 == "d3dmetal") == (form.wine == "gptk") }, id: \.self) {
                                    Text(Theme.gfxName($0)).tag($0)
                                }
                            }
                        }
                    }
                }
                .disabled(form.started)

                if form.started, let activity = library.activity {
                    Section {
                        ActivityView(activity: activity)
                        if let report = form.report {
                            result(report)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 480)
        .frame(minHeight: 380)
        .onAppear(perform: preset)
        .onChange(of: form.kind) { form.suggestName() }
        .onChange(of: form.installer) { form.suggestName() }
        .onChange(of: form.wine) { form.gfx = form.wine == "gptk" ? "d3dmetal" : library.inventory.defaults.gfx }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(form.started && !running ? "Hotovo" : "Zrušit") {
                    library.dismissActivity()
                    dismiss()
                }
                .disabled(running)
            }
            if !form.started || running {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Nainstalovat") { install() }
                        .disabled(!canInstall || running)
                }
            }
        }
        .interactiveDismissDisabled(running)
    }

    @ViewBuilder
    private func result(_ report: InstallReport) -> some View {
        if report.added.isEmpty {
            Label("Instalátor nevytvořil žádné zástupce. Program přidáš v prefixu tlačítkem Přidat program.",
                  systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Přidáno do knihovny").font(.headline)
                ForEach(report.added, id: \.self) { program in
                    Label(program.name, systemImage: program.exe.lowercased().hasSuffix("\\steam.exe") ? "storefront" : "gamecontroller")
                }
            }
        }
    }

    private func preset() {
        form.taken = Set(library.inventory.prefixes.map(\.name))
        form.wine = library.inventory.defaults.wine
        form.gfx = library.inventory.defaults.gfx
        if let prefix = request.prefix { form.prefix = prefix }
        switch request.source {
        case .steam: form.kind = .steam
        case .installer(let url):
            form.kind = .installer
            form.installer = url
            if url == nil { DispatchQueue.main.async(execute: chooseInstaller) }
        case nil: break
        }
        form.suggestName()
    }

    private func chooseInstaller() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.exe, UTType(filenameExtension: "msi") ?? .data]
        panel.message = "Vyber instalátor hry pro Windows"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        form.installer = url
    }

    private func install() {
        guard let source = form.source else { return }
        form.started = true
        let name = existing ? form.prefix : form.name
        Task {
            form.report = await library.install(source, into: name, wine: form.wine, gfx: form.gfx)
        }
    }
}
