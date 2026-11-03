import AppKit
import JackCore
import SwiftUI
import UniformTypeIdentifiers

struct CustomizationSettingsView: View {
    @ObservedObject var center: CustomizationCenter
    @State private var selectedID: String?
    @State private var json = ""
    @State private var importJSON = ""
    @State private var importError: String?
    @State private var savedJSON = ""
    @State private var validation: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var showingImport = false
    @State private var confirmingRemoval = false

    // Keep the quick controls usable while a color/name is temporarily invalid;
    // strict validation belongs to the save path.
    private var draftPack: CustomizationPack? { try? JSONDecoder().decode(CustomizationPack.self, from: Data(json.utf8)) }
    private var selectedPack: CustomizationPack? { center.packs.first { $0.id == selectedID } }
    private var enabled: Bool { selectedID.map(center.enabledIDs.contains) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Personalización").font(.system(size: 17, weight: .semibold))
                    Text("Edita paquetes JSON; los cambios válidos se aplican en vivo.")
                        .font(.system(size: 10.5)).foregroundStyle(JackPalette.muted)
                }
                Spacer()
                Button { NSWorkspace.shared.open(center.directory) } label: { Image(systemName: "folder") }
                    .help("Abrir carpeta de paquetes")
                Button { reset() } label: { Image(systemName: "arrow.counterclockwise") }
                    .help("Deshabilitar todos los paquetes")
            }

            HStack(spacing: 6) {
                Button("Nuevo") { createPack() }
                Button("Importar…") { importFile() }
                Button("Exportar…") { exportSelected() }.disabled(selectedPack == nil)
                Spacer()
                if let selectedID {
                    Toggle("Activo", isOn: Binding(get: { enabled }, set: { setEnabled($0, id: selectedID) }))
                        .toggleStyle(.switch).controlSize(.small)
                }
            }

            if center.packs.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "paintpalette").foregroundStyle(JackPalette.muted)
                    Text("Sin paquetes").font(.system(size: 12, weight: .medium))
                    Text("Crea un paquete o importa un archivo JSON.").font(.system(size: 10)).foregroundStyle(JackPalette.muted)
                }.frame(maxWidth: .infinity).frame(height: 80)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(center.packs, id: \.id) { pack in
                            Button {
                                guard flushDraft() else { return }
                                saveTask?.cancel()
                                selectedID = pack.id
                                load(pack)
                            } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(center.enabledIDs.contains(pack.id) ? JackPalette.green : JackPalette.muted).frame(width: 6, height: 6)
                                    Text(pack.name).lineLimit(1)
                                }
                                .font(.system(size: 10.5, weight: selectedID == pack.id ? .semibold : .regular))
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .background(selectedID == pack.id ? JackPalette.selection : JackPalette.panel, in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }.scrollIndicators(.hidden)
            }

            if let pack = selectedPack {
                HStack {
                    Text(pack.id).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(JackPalette.muted)
                    Spacer()
                    Button("+ Tema") { updateDraft { if $0.theme == nil { $0.theme = CustomizationTheme(appearance: .system) } } }
                    Button("+ Layout") { updateDraft { if $0.layout == nil { $0.layout = CustomizationLayout(interface: .basic) } } }
                    Button("+ Comando") { addCommand() }
                    Button(role: .destructive) { confirmingRemoval = true } label: { Image(systemName: "trash") }
                        .help("Eliminar paquete")
                }.font(.system(size: 10))

                DisclosureGroup("Controles rápidos") { quickControls }
                    .font(.system(size: 10.5, weight: .medium))

                TextEditor(text: $json)
                    .font(.system(size: 10, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .background(JackPalette.codeBackground, in: RoundedRectangle(cornerRadius: JackPalette.radius(7)))
                    .overlay(RoundedRectangle(cornerRadius: JackPalette.radius(7)).stroke(JackPalette.hairline))
                    .frame(minHeight: 175, maxHeight: .infinity)
                    .onChange(of: json) { _, text in validateAndSave(text) }
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: validation == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(validation == nil ? JackPalette.green : JackPalette.red)
                Text(validation ?? "Valida cada edición mientras escribes; los JSON inválidos no se guardan ni se aplican.")
                    .foregroundStyle(validation == nil ? JackPalette.muted : JackPalette.red).textSelection(.enabled)
                Spacer(minLength: 0)
            }.font(.system(size: 9.5)).lineLimit(2)

            if json != savedJSON || validation != nil {
                Button("Descartar borrador y recargar") { discardDraftAndReload() }
                    .font(.system(size: 9)).buttonStyle(.link)
            }

            if let error = center.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5)).foregroundStyle(JackPalette.red).textSelection(.enabled)
            }
        }
        .padding(13)
        .frame(minWidth: 470, minHeight: 420)
        .onAppear { if selectedID == nil, let pack = center.packs.first { selectedID = pack.id; load(pack) } }
        .onChange(of: center.revision) { _, _ in
            guard let selectedID, let pack = center.packs.first(where: { $0.id == selectedID }) else { return }
            let latest = encoded(pack)
            if json == savedJSON {
                load(pack)
            } else if latest != savedJSON {
                saveTask?.cancel()
                validation = "El paquete cambió en disco mientras editabas. Copia tu borrador antes de seleccionar otra versión."
            }
        }
        .onDisappear { saveTask?.cancel(); saveTask = nil }
        .confirmationDialog("¿Eliminar este paquete?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Eliminar paquete", role: .destructive) { removeSelected() }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("Se eliminará su archivo y se deshabilitará.") }
        .sheet(isPresented: $showingImport) { importEditor }
    }

    @ViewBuilder private var quickControls: some View {
        if let pack = draftPack {
            VStack(alignment: .leading, spacing: 7) {
                if pack.theme != nil {
                    Text("Tema").font(.system(size: 9, weight: .semibold)).foregroundStyle(JackPalette.muted)
                    Picker("Apariencia", selection: themeAppearance) {
                        Text("Sistema").tag(CustomizationTheme.Appearance.system)
                        Text("Clara").tag(CustomizationTheme.Appearance.light)
                        Text("Oscura").tag(CustomizationTheme.Appearance.dark)
                    }.labelsHidden().frame(maxWidth: 130)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 5)], alignment: .leading, spacing: 5) {
                        themeField("Canvas", \.canvas); themeField("Chrome", \.chrome); themeField("Panel", \.panel)
                        themeField("Selection", \.selection); themeField("Accent", \.accent); themeField("Text", \.text); themeField("Muted", \.muted)
                    }
                }
                if pack.layout != nil {
                    Text("Layout").font(.system(size: 9, weight: .semibold)).foregroundStyle(JackPalette.muted)
                    HStack {
                        Picker("Interfaz", selection: layoutInterface) {
                            Text("Basic").tag(CustomizationLayout.Interface.basic)
                            Text("Ice").tag(CustomizationLayout.Interface.ice)
                            Text("Terminal").tag(CustomizationLayout.Interface.terminal)
                            Text("Oficina 3D").tag(CustomizationLayout.Interface.office)
                            Text("Oficina 2D").tag(CustomizationLayout.Interface.office2D)
                        }.labelsHidden().frame(maxWidth: 150)
                        Picker("Sidebar", selection: sidebarPosition) {
                            Text("Izquierda").tag(CustomizationLayout.SidebarPosition.left)
                            Text("Derecha").tag(CustomizationLayout.SidebarPosition.right)
                        }.labelsHidden().frame(maxWidth: 120)
                        Picker("Workspace", selection: workspacePosition) {
                            Text("Derecha").tag(CustomizationLayout.WorkspacePosition.right)
                            Text("Abajo").tag(CustomizationLayout.WorkspacePosition.bottom)
                        }.labelsHidden().frame(maxWidth: 110)
                    }
                    HStack {
                        Toggle("Sidebar", isOn: layoutBool(\.sidebarVisible))
                        Toggle("Status bar", isOn: layoutBool(\.statusBarVisible))
                        Toggle("Explorer", isOn: layoutBool(\.explorerVisible))
                    }.font(.system(size: 9))
                    HStack(spacing: 5) {
                        layoutNumber("Sidebar px", \.sidebarWidth)
                        layoutNumber("Workspace px", \.workspaceWidth)
                        layoutNumber("Workspace alto", \.workspaceHeight)
                    }
                }
                if !pack.commands.isEmpty {
                    Text("Comandos · nombre, título, tipo y contenido").font(.system(size: 9, weight: .semibold)).foregroundStyle(JackPalette.muted)
                    ForEach(Array(pack.commands.enumerated()), id: \.offset) { index, command in
                        HStack(spacing: 5) {
                            TextField("Nombre", text: commandText(index, \.name))
                            TextField("Título", text: commandText(index, \.title))
                            Picker("Tipo", selection: commandKind(index)) {
                                Text("Prompt").tag(CustomizationCommand.Kind.prompt)
                                Text("Terminal").tag(CustomizationCommand.Kind.terminal)
                            }.labelsHidden().frame(width: 88)
                        }
                        TextField(command.kind == .prompt ? "Contenido del prompt" : "Comando de terminal", text: commandText(index, \.content), axis: .vertical)
                            .lineLimit(1...3).font(.system(size: 9.5, design: .monospaced))
                    }
                }
            }.padding(.top, 6)
        }
    }

    private var importEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Importar paquete JSON").font(.headline)
            TextEditor(text: $importJSON).font(.system(size: 11, design: .monospaced)).frame(minWidth: 520, minHeight: 300)
                .onChange(of: importJSON) { _, _ in importError = nil }
            if let importError { Text(importError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancelar") { showingImport = false; importJSON = ""; importError = nil }
                Button("Validar e importar") { importDraft() }.keyboardShortcut(.defaultAction)
            }
        }.padding(18)
    }

    private func load(_ pack: CustomizationPack) {
        guard let value = encoded(pack) else { return }
        json = value; savedJSON = value; validation = nil
    }

    private func encoded(_ pack: CustomizationPack) -> String? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(pack) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func validateAndSave(_ text: String) {
        guard selectedID != nil else { saveTask?.cancel(); return }
        do {
            let pack = try CustomizationCenter.decodePack(Data(text.utf8))
            guard pack.id == selectedID else { throw EditorError.idChanged }
            validation = nil; saveTask?.cancel()
            guard text != savedJSON else { return }
            saveTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, selectedID == pack.id, json == text,
                      let current = center.packs.first(where: { $0.id == pack.id }), encoded(current) == savedJSON else { return }
                do { try center.save(pack); savedJSON = text; validation = nil }
                catch { validation = error.localizedDescription }
            }
        } catch { saveTask?.cancel(); validation = error.localizedDescription }
    }

    @discardableResult private func flushDraft() -> Bool {
        guard json != savedJSON else { return true }
        do {
            let pack = try CustomizationCenter.decodePack(Data(json.utf8))
            guard pack.id == selectedID else { throw EditorError.idChanged }
            guard let current = center.packs.first(where: { $0.id == pack.id }), encoded(current) == savedJSON else {
                throw EditorError.externalChange
            }
            saveTask?.cancel(); try center.save(pack); savedJSON = json; validation = nil; return true
        } catch { validation = error.localizedDescription; return false }
    }

    private func discardDraftAndReload() {
        saveTask?.cancel()
        saveTask = nil
        guard let selectedID, let pack = center.packs.first(where: { $0.id == selectedID }) else {
            selectedID = nil
            json = ""
            savedJSON = ""
            validation = nil
            return
        }
        load(pack)
    }

    private func createPack() {
        guard flushDraft() else { return }
        let id = "pack-" + UUID().uuidString.lowercased()
        let pack = CustomizationPack(id: id, name: "Nuevo paquete")
        do { try center.save(pack); try center.setPackEnabled(id, true); selectedID = id; load(pack) }
        catch { validation = error.localizedDescription }
    }

    private func updateDraft(_ edit: (inout CustomizationPack) -> Void) {
        do {
            var pack = try JSONDecoder().decode(CustomizationPack.self, from: Data(json.utf8)); edit(&pack)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            json = String(decoding: try encoder.encode(pack), as: UTF8.self)
        } catch { validation = error.localizedDescription }
    }

    private func addCommand() {
        updateDraft {
            $0.commands.append(CustomizationCommand(name: "custom-\($0.commands.count + 1)", title: "Nuevo comando", kind: .prompt, content: "{{args}}"))
        }
    }

    private func themeField(_ title: String, _ keyPath: WritableKeyPath<CustomizationTheme, String?>) -> some View {
        TextField(title, text: Binding(get: { draftPack?.theme?[keyPath: keyPath] ?? "" }, set: { value in
            updateDraft { var theme = $0.theme ?? CustomizationTheme(); theme[keyPath: keyPath] = value.isEmpty ? nil : value; $0.theme = theme }
        })).font(.system(size: 9, design: .monospaced)).textFieldStyle(.roundedBorder)
    }

    private var themeAppearance: Binding<CustomizationTheme.Appearance> {
        Binding(get: { draftPack?.theme?.appearance ?? .system }, set: { value in updateDraft { var v = $0.theme ?? CustomizationTheme(); v.appearance = value; $0.theme = v } })
    }

    private var layoutInterface: Binding<CustomizationLayout.Interface> {
        Binding(get: { draftPack?.layout?.interface ?? .basic }, set: { value in updateDraft { var v = $0.layout ?? CustomizationLayout(); v.interface = value; $0.layout = v } })
    }
    private var sidebarPosition: Binding<CustomizationLayout.SidebarPosition> {
        Binding(get: { draftPack?.layout?.sidebarPosition ?? .left }, set: { value in updateDraft { var v = $0.layout ?? CustomizationLayout(); v.sidebarPosition = value; $0.layout = v } })
    }
    private var workspacePosition: Binding<CustomizationLayout.WorkspacePosition> {
        Binding(get: { draftPack?.layout?.workspacePosition ?? .right }, set: { value in updateDraft { var v = $0.layout ?? CustomizationLayout(); v.workspacePosition = value; $0.layout = v } })
    }
    private func layoutBool(_ keyPath: WritableKeyPath<CustomizationLayout, Bool?>) -> Binding<Bool> {
        Binding(get: { draftPack?.layout?[keyPath: keyPath] ?? false }, set: { value in updateDraft { var v = $0.layout ?? CustomizationLayout(); v[keyPath: keyPath] = value; $0.layout = v } })
    }
    private func layoutNumber(_ title: String, _ keyPath: WritableKeyPath<CustomizationLayout, Int?>) -> some View {
        TextField(title, text: Binding(get: {
            guard let value = draftPack?.layout?[keyPath: keyPath] else { return "" }
            return String(value)
        }, set: { text in
            guard text.isEmpty || Int(text) != nil else { validation = "El ancho debe ser un número entero."; return }
            updateDraft { var v = $0.layout ?? CustomizationLayout(); v[keyPath: keyPath] = text.isEmpty ? nil : Int(text); $0.layout = v }
        })).font(.system(size: 9, design: .monospaced)).textFieldStyle(.roundedBorder)
    }
    private func commandText(_ index: Int, _ keyPath: WritableKeyPath<CustomizationCommand, String>) -> Binding<String> {
        Binding(get: { draftPack?.commands.indices.contains(index) == true ? draftPack!.commands[index][keyPath: keyPath] : "" }, set: { value in
            updateDraft { if $0.commands.indices.contains(index) { $0.commands[index][keyPath: keyPath] = value } }
        })
    }
    private func commandKind(_ index: Int) -> Binding<CustomizationCommand.Kind> {
        Binding(get: { draftPack?.commands.indices.contains(index) == true ? draftPack!.commands[index].kind : .prompt }, set: { value in
            updateDraft { if $0.commands.indices.contains(index) { $0.commands[index].kind = value } }
        })
    }

    private func setEnabled(_ value: Bool, id: String) {
        do { try center.setPackEnabled(id, value); validation = nil }
        catch { validation = error.localizedDescription }
    }
    private func reset() {
        do { for id in center.enabledIDs { try center.setPackEnabled(id, false) } }
        catch { validation = error.localizedDescription }
    }
    private func removeSelected() {
        guard let selectedID else { return }
        saveTask?.cancel()
        do {
            try center.removePack(selectedID); self.selectedID = center.packs.first?.id
            if let pack = center.packs.first { load(pack) } else { json = ""; savedJSON = "" }
        } catch { validation = error.localizedDescription }
    }
    private func exportSelected() {
        guard flushDraft(), let selectedID else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "\(selectedID).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try center.exportPack(id: selectedID).write(to: url, options: .atomic) }
        catch { validation = error.localizedDescription }
    }
    private func importFile() {
        guard flushDraft() else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= 1_048_576 else {
                throw CocoaError(.fileReadTooLarge)
            }
            importJSON = String(decoding: try Data(contentsOf: url), as: UTF8.self); importError = nil; showingImport = true
        } catch { validation = error.localizedDescription }
    }
    private func importDraft() {
        do {
            let id = try center.importPack(data: Data(importJSON.utf8))
            saveTask?.cancel()
            selectedID = id
            if let pack = center.packs.first(where: { $0.id == id }) { load(pack) }
            showingImport = false; importJSON = ""; importError = nil; validation = nil
        } catch { importError = error.localizedDescription }
    }

    private enum EditorError: LocalizedError {
        case idChanged, externalChange
        var errorDescription: String? {
            switch self {
            case .idChanged: "El id no se puede cambiar aquí; crea un paquete o importa otro."
            case .externalChange: "El paquete cambió fuera del editor. Copia tu borrador antes de continuar."
            }
        }
    }
}
