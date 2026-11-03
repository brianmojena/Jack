#if canImport(JackCore)
import JackCore
#endif
import SwiftUI

/// La tarjeta para ajustar a un personaje: con qué modelo piensa (cualquiera de Stellar Code, Claude Code, Codex u OpenCode; sin
/// elegir, Gemma), su personalidad (el texto con que se le explica cómo es) y si está encendida. Mismo estilo que el resto de
/// tarjetas de la oficina.
struct OfficePersonaEditor<Host: OfficeHost>: View {
    let name: String
    let thumbnail: PlatformImage?
    /// La personalidad que trae el avatar (para poder volver a ella), si la trae.
    let originalProfile: String?
    @ObservedObject var store: Host
    let onSave: (_ brain: OfficeBrainChoice?, _ profile: String, _ personalityOff: Bool) -> Void
    let onClose: () -> Void

    /// Gemma es «sin elegir».
    @State private var provider: ChatProvider?
    @State private var model: String
    @State private var profile: String
    @State private var off: Bool
    @State private var openCode: [OpenCodeProviderModels] = []
    @State private var openCodeState = OpenCodeState.idle

    private enum OpenCodeState: Equatable { case idle, loading, failed(String), ready }

    private static var navy: Color { Color(red: 0.11, green: 0.25, blue: 0.46) }

    init(name: String, thumbnail: PlatformImage?, originalProfile: String?, brain: OfficeBrainChoice?, profile: String, personalityOff: Bool, store: Host,
         onSave: @escaping (OfficeBrainChoice?, String, Bool) -> Void, onClose: @escaping () -> Void) {
        self.name = name
        self.thumbnail = thumbnail
        self.originalProfile = originalProfile
        self.store = store
        self.onSave = onSave
        self.onClose = onClose
        _provider = State(initialValue: brain?.provider)
        _model = State(initialValue: brain?.model ?? "")
        _profile = State(initialValue: profile)
        _off = State(initialValue: personalityOff)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { OfficeSound.back.play(); onClose() }
            card.frame(width: 480)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let thumbnail {
                    Image(platformImage: thumbnail).resizable().scaledToFill().frame(width: 38, height: 38).clipShape(Circle())
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cerebro y personalidad").font(.system(size: 15, weight: .semibold))
                    Text(name).font(.system(size: 12.5)).opacity(0.7)
                }
                Spacer()
                Button { OfficeSound.back.play(); onClose() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).opacity(0.7)
                        .frame(width: 22, height: 22).background(Color(red: 0.9, green: 0.93, blue: 0.97), in: Circle())
                }
                .buttonStyle(.plain)
            }
            modelSection
            Divider()
            personalitySection
            HStack {
                Spacer()
                Button("Cancelar") { OfficeSound.back.play(); onClose() }.keyboardShortcut(.cancelAction)
                Button("Guardar") {
                    OfficeSound.select.play()
                    let choice = provider.map { OfficeBrainChoice(provider: $0, model: model.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    onSave(choice, profile, off)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(provider == .stellar && model.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .foregroundStyle(Self.navy)
        .padding(18)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(red: 0.74, green: 0.8, blue: 0.88), lineWidth: 1))
        .shadow(color: .black.opacity(0.32), radius: 12, y: 5)
        .onChange(of: provider) { _, new in
            // Al cambiar de proveedor, lo que había escrito era de otro.
            if new != nil { model = "" }
            if new == .opencode { loadOpenCode() }
        }
        .onAppear { if provider == .opencode { loadOpenCode() } }
    }

    // MARK: - Modelo

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Modelo con que piensa").font(.system(size: 13, weight: .semibold))
            Picker("Proveedor", selection: $provider) {
                Text("Gemma (predeterminado)").tag(ChatProvider?.none)
                ForEach(ChatProvider.allCases) { Text($0.title).tag(ChatProvider?.some($0)) }
            }
            .labelsHidden()
            if let provider {
                modelList(for: provider)
                TextField(placeholder(for: provider), text: $model).textFieldStyle(.roundedBorder).font(.system(size: 12.5, design: .monospaced))
                Text(footnote(for: provider)).font(.system(size: 11.5)).opacity(0.65).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(OfficeNarrator.modelName) en Ollama Cloud, como hasta ahora.").font(.system(size: 11.5)).opacity(0.65)
            }
        }
    }

    /// Los modelos que se conocen del proveedor, en una lista donde se pulsa uno; abajo se puede escribir otro a mano.
    @ViewBuilder private func modelList(for provider: ChatProvider) -> some View {
        let options = choices(for: provider)
        if provider == .opencode, openCodeState == .loading {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Consultando los modelos de OpenCode…").font(.system(size: 12)).opacity(0.7) }
                .frame(maxWidth: .infinity, minHeight: 60)
        } else if provider == .opencode, case .failed(let message) = openCodeState {
            VStack(alignment: .leading, spacing: 4) {
                Text("No se pudieron cargar los modelos de OpenCode.").font(.system(size: 12, weight: .semibold))
                Text(message).font(.system(size: 11.5)).opacity(0.7).lineLimit(3)
                Button("Reintentar") { loadOpenCode() }.officeLinkButton().font(.system(size: 11.5))
            }
        } else if options.isEmpty {
            Text("No hay modelos conocidos: escribe el id abajo.").font(.system(size: 12)).opacity(0.65)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(options, id: \.id) { option in
                        let selected = option.id == model
                        Button { model = option.id } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 12))
                                    .foregroundStyle(selected ? Color(red: 0.22, green: 0.55, blue: 0.95) : Self.navy.opacity(0.35))
                                Text(option.title).font(.system(size: 12.5, weight: selected ? .semibold : .regular)).lineLimit(1)
                                if option.title != option.id {
                                    Text(option.id).font(.system(size: 10.5, design: .monospaced)).opacity(0.5).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(selected ? Color(red: 0.88, green: 0.95, blue: 1) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
            }
            .frame(height: min(CGFloat(options.count) * 29 + 8, 150))
            .background(Color(red: 0.95, green: 0.97, blue: 1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(red: 0.74, green: 0.8, blue: 0.88), lineWidth: 1))
        }
    }

    private func placeholder(for provider: ChatProvider) -> String {
        switch provider {
        case .claude: "alias o modelo (vacío: \(provider.defaultModel))"
        case .codex: "modelo (vacío: \(provider.defaultModel))"
        case .opencode: "proveedor/modelo (vacío: el predeterminado)"
        case .stellar: "servidor/modelo, por ejemplo ollama/gemma4:31b-cloud"
        case .antigravity, .qoder: "modelo (vacío: el predeterminado)"
        }
    }

    private func footnote(for provider: ChatProvider) -> String {
        switch provider {
        case .stellar: "Se consulta directamente a su servidor. Es el único que ve la imagen de los cuadros y del tablero."
        default: "Se lanza \(provider.title) en una consulta suelta, sin herramientas ni historial. Tarda unos segundos más y no ve imágenes."
        }
    }

    private func choices(for provider: ChatProvider) -> [(id: String, title: String)] {
        if provider == .opencode { return openCode.flatMap { group in group.models.map { (id: $0.id, title: "\(group.title) · \($0.title)") } } }
        return store.modelChoices(for: provider).map { (id: $0.id, title: $0.title.isEmpty ? $0.id : $0.title) }
    }

    private func loadOpenCode() {
        guard openCodeState == .idle || { if case .failed = openCodeState { return true } else { return false } }() else { return }
        openCodeState = .loading
        #if os(macOS)
        let directory = FileManager.default.homeDirectoryForCurrentUser.path
        Task {
            do {
                openCode = try await OpenCodeModelService.list(directory: directory)
                openCodeState = .ready
            } catch {
                openCodeState = .failed(error.localizedDescription)
            }
        }
        #else
        // En el iPhone, los modelos de OpenCode que conoce la Mac (si no, se escribe a mano).
        let models = store.modelChoices(for: .opencode)
        openCode = models.isEmpty ? [] : [OpenCodeProviderModels(id: "mac", title: "OpenCode", models: models)]
        openCodeState = .ready
        #endif
    }

    // MARK: - Personalidad

    private var personalitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Personalidad").font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("Encendida", isOn: Binding(get: { !off }, set: { off = !$0 })).toggleStyle(.switch).controlSize(.small)
            }
            TextEditor(text: $profile)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 120)
                .background(Color(red: 0.95, green: 0.97, blue: 1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(red: 0.74, green: 0.8, blue: 0.88), lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if profile.isEmpty {
                        Text("Cómo es, cómo habla, qué le gusta… («Eres …»)").font(.system(size: 12.5)).opacity(0.4).padding(.horizontal, 11).padding(.vertical, 14).allowsHitTesting(false)
                    }
                }
                .opacity(off ? 0.5 : 1)
            HStack {
                Text(off ? "Apagada: habla como un compañero normal. El texto se conserva." : "Se le da al modelo para que hable y actúe a su manera.")
                    .font(.system(size: 11.5)).opacity(0.65)
                Spacer()
                if let originalProfile, profile.trimmingCharacters(in: .whitespacesAndNewlines) != originalProfile.trimmingCharacters(in: .whitespacesAndNewlines) {
                    Button("Restaurar original") { profile = originalProfile }.officeLinkButton().font(.system(size: 11.5))
                }
            }
        }
    }
}
