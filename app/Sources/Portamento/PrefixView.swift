import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct PrefixView: View {
    @Environment(Library.self) private var library
    var prefix: Prefix

    /// D3DMetal comes with its own Wine; the other backends run on any other Wine.
    private var backends: [String] {
        library.inventory.backends.keys.sorted().filter { ($0 == "d3dmetal") == (prefix.wine == "gptk") }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 6) {
                    Tag(Theme.wineName(prefix.wine))
                    Tag(Theme.gfxName(prefix.gfx))
                    Tag(Theme.vulkanName(prefix.vulkan))
                    if prefix.wine == "cx" { Tag("msync", tint: .green) }
                }
            }

            Section {
                Picker("Grafická vrstva", selection: binding(\.gfx, key: "gfx")) {
                    ForEach(backends, id: \.self) { Text(Theme.gfxName($0)).tag($0) }
                }
                Picker("Ovladač Vulkanu", selection: binding(\.vulkan, key: "vulkan")) {
                    ForEach(library.inventory.vulkan.keys.sorted(), id: \.self) { Text(Theme.vulkanName($0)).tag($0) }
                }
                .disabled(prefix.wine == "gptk")
                LabeledContent("Wine", value: Theme.wineName(prefix.wine))
            } header: {
                Text("Grafika")
            } footer: {
                Text("Wine se u prefixu nedá změnit, každé si prefix upraví pro svou verzi. Pro jiné Wine vytvoř nový prefix.")
            }

            Section("Programy") {
                ForEach(prefix.programs) { program in
                    HStack {
                        Label(program.name, systemImage: Theme.symbol(for: program))
                        Spacer()
                        Button("Spustit", systemImage: "play.fill") {
                            Task { await library.launch(LibraryItem(program: program, prefix: prefix)) }
                        }
                        .labelStyle(.iconOnly)
                    }
                }
                Button("Přidat program…", systemImage: "plus") { addProgram() }
            }

            if !prefix.env.isEmpty {
                Section("Proměnné prostředí") {
                    ForEach(prefix.env.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        LabeledContent(key, value: value).monospaced()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(prefix.name)
        .toolbar {
            Button("Disk C:", systemImage: "folder") { NSWorkspace.shared.open(prefix.driveC) }
            Button("Ukončit vše", systemImage: "stop.fill") { Task { await library.kill(prefix) } }
        }
    }

    /// A setting that writes through to porta when changed.
    private func binding(_ path: KeyPath<Prefix, String>, key: String) -> Binding<String> {
        Binding(get: { prefix[keyPath: path] },
                set: { value in Task { await library.set(prefix, key, value) } })
    }

    private func addProgram() {
        let panel = NSOpenPanel()
        panel.directoryURL = prefix.driveC
        panel.allowedContentTypes = [.exe]
        panel.message = "Vyber program pro Windows v disku C: tohoto prefixu"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await library.addProgram(to: prefix, name: url.deletingPathExtension().lastPathComponent, exe: url) }
    }
}

extension UTType {
    static let exe = UTType(filenameExtension: "exe") ?? .data
}

final class NewPrefixForm: ObservableObject {
    @Published var name = ""
    @Published var wine = "cx"
    @Published var gfx = "dxmt"
}

struct NewPrefixSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = NewPrefixForm()

    var body: some View {
        Form {
            TextField("Název", text: $form.name, prompt: Text("moje-hra"))
            Picker("Wine", selection: $form.wine) {
                ForEach(library.inventory.wines.filter(\.value).keys.sorted(), id: \.self) {
                    Text(Theme.wineName($0)).tag($0)
                }
            }
            Picker("Grafická vrstva", selection: $form.gfx) {
                ForEach(library.inventory.backends.keys.sorted().filter { ($0 == "d3dmetal") == (form.wine == "gptk") },
                        id: \.self) { Text(Theme.gfxName($0)).tag($0) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onChange(of: form.wine) { form.gfx = form.wine == "gptk" ? "d3dmetal" : "dxmt" }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Zrušit") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Vytvořit") {
                    Task {
                        await library.create(name: form.name, wine: form.wine, gfx: form.gfx)
                        dismiss()
                    }
                }
                .disabled(form.name.isEmpty || form.name.contains("/"))
            }
        }
    }
}
