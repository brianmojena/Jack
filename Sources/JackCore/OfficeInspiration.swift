import Foundation

/// Un cuadro famoso para reproducir en la pizarra.
public struct OfficeArtwork: Equatable, Sendable {
    /// Cómo se llama en español.
    public var title: String
    public var author: String
    /// Qué buscar en Wikimedia Commons (en inglés, que es como están titulados casi todos los archivos).
    var query: String

    /// «La noche estrellada», de Vincent van Gogh.
    public var label: String { "«\(title)», de \(author)" }
}

/// El cuadro elegido y, si se encontró, la imagen que se descargó de internet.
public struct OfficeInspiration: Equatable, Sendable {
    public var artwork: OfficeArtwork
    /// Cómo se llama el archivo en Wikimedia Commons, sin la extensión («Mona Lisa, by Leonardo da Vinci»).
    public var fileTitle: String?
    /// La imagen (JPEG o PNG, una miniatura), o `nil` si no se pudo descargar.
    public var image: Data?
}

/// Oficina 3D (modo Normal): elige un cuadro famoso al azar y busca su imagen en Wikimedia Commons, que no pide clave, para que quien
/// dibuja en la pizarra lo reproduzca a su manera. Solo se descargan miniaturas JPEG o PNG de los servidores de imágenes de Wikimedia.
public struct OfficeInspirationFinder: Sendable {
    public enum Failure: Error, Equatable {
        case notAnImage
    }

    public var fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.fetch = fetch
    }

    /// Cuadros muy conocidos (casi todos de dominio público) con colores y composición reconocibles. Sin desnudos.
    public static let works: [OfficeArtwork] = [
        .init(title: "La Gioconda", author: "Leonardo da Vinci", query: "Mona Lisa Leonardo da Vinci"),
        .init(title: "La noche estrellada", author: "Vincent van Gogh", query: "The Starry Night Van Gogh"),
        .init(title: "El grito", author: "Edvard Munch", query: "The Scream Munch 1893"),
        .init(title: "La joven de la perla", author: "Johannes Vermeer", query: "Girl with a Pearl Earring Vermeer"),
        .init(title: "Las Meninas", author: "Diego Velázquez", query: "Las Meninas Velázquez"),
        .init(title: "El beso", author: "Gustav Klimt", query: "The Kiss Klimt 1908"),
        .init(title: "La gran ola de Kanagawa", author: "Hokusai", query: "The Great Wave off Kanagawa Hokusai"),
        .init(title: "Los girasoles", author: "Vincent van Gogh", query: "Sunflowers Van Gogh 1888"),
        .init(title: "La última cena", author: "Leonardo da Vinci", query: "The Last Supper Leonardo da Vinci"),
        .init(title: "Impresión, sol naciente", author: "Claude Monet", query: "Impression, Sunrise Monet"),
        .init(title: "Los nenúfares", author: "Claude Monet", query: "Water Lilies Monet 1906"),
        .init(title: "Mujer con sombrilla", author: "Claude Monet", query: "Woman with a Parasol Monet"),
        .init(title: "Terraza de café por la noche", author: "Vincent van Gogh", query: "Café Terrace at Night Van Gogh"),
        .init(title: "La habitación en Arlés", author: "Vincent van Gogh", query: "Bedroom in Arles Van Gogh"),
        .init(title: "Autorretrato con la oreja vendada", author: "Vincent van Gogh", query: "Self-Portrait with Bandaged Ear Van Gogh"),
        .init(title: "Almendro en flor", author: "Vincent van Gogh", query: "Almond Blossom Van Gogh"),
        .init(title: "Los comedores de patatas", author: "Vincent van Gogh", query: "The Potato Eaters Van Gogh"),
        .init(title: "El caminante sobre el mar de nubes", author: "Caspar David Friedrich", query: "Wanderer above the Sea of Fog"),
        .init(title: "La libertad guiando al pueblo", author: "Eugène Delacroix", query: "Liberty Leading the People Delacroix"),
        .init(title: "La balsa de la Medusa", author: "Théodore Géricault", query: "The Raft of the Medusa Géricault"),
        .init(title: "La ronda de noche", author: "Rembrandt", query: "The Night Watch Rembrandt"),
        .init(title: "Los fusilamientos del 3 de mayo", author: "Francisco de Goya", query: "The Third of May 1808 Goya"),
        .init(title: "Saturno devorando a su hijo", author: "Francisco de Goya", query: "Saturn Devouring His Son Goya"),
        .init(title: "La rendición de Breda", author: "Diego Velázquez", query: "The Surrender of Breda Velázquez"),
        .init(title: "La escuela de Atenas", author: "Rafael", query: "The School of Athens Raphael"),
        .init(title: "La primavera", author: "Sandro Botticelli", query: "Primavera Botticelli"),
        .init(title: "Un domingo en la Grande Jatte", author: "Georges Seurat", query: "A Sunday Afternoon on the Island of La Grande Jatte"),
        .init(title: "El almuerzo de los remeros", author: "Pierre-Auguste Renoir", query: "Luncheon of the Boating Party Renoir"),
        .init(title: "Los jugadores de cartas", author: "Paul Cézanne", query: "The Card Players Cézanne"),
        .init(title: "La carreta de heno", author: "John Constable", query: "The Hay Wain Constable"),
        .init(title: "Napoleón cruzando los Alpes", author: "Jacques-Louis David", query: "Napoleon Crossing the Alps David"),
        .init(title: "La dama del armiño", author: "Leonardo da Vinci", query: "Lady with an Ermine Leonardo"),
        .init(title: "Cazadores en la nieve", author: "Pieter Bruegel el Viejo", query: "Hunters in the Snow Bruegel"),
        .init(title: "La torre de Babel", author: "Pieter Bruegel el Viejo", query: "The Tower of Babel Bruegel 1563"),
        .init(title: "Paisaje con la caída de Ícaro", author: "Pieter Bruegel el Viejo", query: "Landscape with the Fall of Icarus Bruegel"),
        .init(title: "El matrimonio Arnolfini", author: "Jan van Eyck", query: "Arnolfini Portrait Van Eyck"),
        .init(title: "La lechera", author: "Johannes Vermeer", query: "The Milkmaid Vermeer"),
        .init(title: "Vista de Delft", author: "Johannes Vermeer", query: "View of Delft Vermeer"),
        .init(title: "El caballero de la mano en el pecho", author: "El Greco", query: "The Nobleman with his Hand on his Chest El Greco"),
        .init(title: "Vista de Toledo", author: "El Greco", query: "View of Toledo El Greco"),
        .init(title: "Las espigadoras", author: "Jean-François Millet", query: "The Gleaners Millet"),
        .init(title: "Ofelia", author: "John Everett Millais", query: "Ophelia Millais"),
        .init(title: "La dama de Shalott", author: "John William Waterhouse", query: "The Lady of Shalott Waterhouse 1888"),
        .init(title: "La danza", author: "Henri Matisse", query: "Dance Matisse 1910 Hermitage"),
        .init(title: "Gótico americano", author: "Grant Wood", query: "American Gothic Grant Wood"),
    ]

    /// Un cuadro de los que no se han reproducido hace poco (los títulos de `recent`).
    public static func pick(excluding recent: [String] = []) -> OfficeArtwork {
        works.filter { !recent.contains($0.title) }.randomElement() ?? works.randomElement()!
    }

    /// La imagen de `artwork` en internet. Si no se encuentra o no se puede descargar (sin conexión), la inspiración llega sin ella: el
    /// cuadro se pinta de memoria.
    public func inspire(by artwork: OfficeArtwork) async throws -> OfficeInspiration {
        do {
            let candidates = Self.candidates(from: try await fetch(Self.request(searching: artwork.query)).0)
            // Lo primero que sale al buscar un cuadro famoso suele ser el propio cuadro.
            for candidate in candidates.prefix(4) {
                try Task.checkCancellation()
                if let image = try? await download(candidate.thumbnail) {
                    return OfficeInspiration(artwork: artwork, fileTitle: candidate.title, image: image)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {}
        return OfficeInspiration(artwork: artwork, fileTitle: nil, image: nil)
    }

    static func request(searching query: String) -> URLRequest {
        var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        components.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"), .init(name: "generator", value: "search"),
            .init(name: "gsrnamespace", value: "6"), .init(name: "gsrsearch", value: "\(query) filetype:bitmap"), .init(name: "gsrlimit", value: "8"),
            .init(name: "prop", value: "imageinfo"), .init(name: "iiprop", value: "url|mime|size"), .init(name: "iiurlwidth", value: "768"),
        ]
        return authorized(URLRequest(url: components.url!, timeoutInterval: 10))
    }

    /// Wikimedia pide que quien llama a su API diga quién es.
    private static func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue("JackOffice/1.0 (macOS app; whiteboard doodles)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Los únicos servidores de los que se descarga (Wikimedia sirve las miniaturas desde cualquiera de los dos).
    static let hosts: Set<String> = ["upload.wikimedia.org", "thumb.wikimedia.org"]

    /// Las miniaturas aprovechables de una respuesta de búsqueda: JPEG o PNG, de los servidores de Wikimedia y de un tamaño decente.
    static func candidates(from data: Data) -> [(title: String, thumbnail: URL)] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = (root["query"] as? [String: Any])?["pages"] as? [String: Any] else { return [] }
        var found: [(index: Int, title: String, thumbnail: URL)] = []
        for case let page as [String: Any] in pages.values {
            guard let info = (page["imageinfo"] as? [[String: Any]])?.first,
                  let mime = info["mime"] as? String, mime == "image/jpeg" || mime == "image/png",
                  let text = info["thumburl"] as? String, let url = URL(string: text), url.scheme == "https", Self.hosts.contains(url.host ?? ""),
                  (info["thumbwidth"] as? Int ?? 0) >= 200, let title = page["title"] as? String else { continue }
            found.append((page["index"] as? Int ?? 0, cleanTitle(title), url))
        }
        return found.sorted { $0.index < $1.index }.map { ($0.title, $0.thumbnail) }
    }

    /// «File:Octopus_vulgaris_02.jpg» → «Octopus vulgaris 02».
    static func cleanTitle(_ title: String) -> String {
        var text = title
        if let colon = text.firstIndex(of: ":"), text[..<colon].lowercased() == "file" { text = String(text[text.index(after: colon)...]) }
        if let dot = text.lastIndex(of: "."), text.distance(from: dot, to: text.endIndex) <= 5 { text = String(text[..<dot]) }
        text = text.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 80 ? String(text.prefix(79)) + "…" : text
    }

    private func download(_ url: URL) async throws -> Data {
        let (data, response) = try await fetch(Self.authorized(URLRequest(url: url, timeoutInterval: 12)))
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 == 200, data.count > 500, data.count <= 2_000_000, Self.isImage(data) else { throw Failure.notAnImage }
        return data
    }

    /// Que sea de verdad un JPEG o un PNG (lo dicen sus primeros bytes), no una página de error.
    static func isImage(_ data: Data) -> Bool {
        data.starts(with: [0xFF, 0xD8, 0xFF]) || data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    }
}
