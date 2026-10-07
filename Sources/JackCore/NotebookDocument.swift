import Foundation

/// Lossless JSON for notebook metadata, attachments and MIME bundles we do not interpret.
public enum NotebookJSON: Codable, Equatable {
    case object([String: NotebookJSON]), array([NotebookJSON]), string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode([NotebookJSON].self) { self = .array(v) }
        else { self = .object(try value.decode([String: NotebookJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }

    public var object: [String: NotebookJSON]? { if case .object(let v) = self { return v }; return nil }
    public var array: [NotebookJSON]? { if case .array(let v) = self { return v }; return nil }
    public var text: String? {
        switch self {
        case .string(let v): return v
        case .array(let v): return v.compactMap(\.text).joined()
        default: return nil
        }
    }
    public var integer: Int? { if case .number(let v) = self, v.isFinite, v >= 0, v < Double(Int.max) { return Int(v) }; return nil }

    static func from(_ object: Any) throws -> NotebookJSON {
        try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed))
    }
}

public struct NotebookCell: Identifiable, Equatable {
    public var fields: [String: NotebookJSON]
    public var id: String { fields["id"]?.text ?? "" }
    public var kind: String {
        get { fields["cell_type"]?.text ?? "raw" }
        set {
            fields["cell_type"] = .string(newValue)
            if newValue == "code" { fields["outputs"] = .array([]); fields["execution_count"] = .null }
            else { fields.removeValue(forKey: "outputs"); fields.removeValue(forKey: "execution_count") }
        }
    }
    public var source: String {
        get { fields["source"]?.text ?? "" }
        set { fields["source"] = .string(newValue) }
    }
    public var outputs: [NotebookJSON] {
        get { fields["outputs"]?.array ?? [] }
        set { fields["outputs"] = .array(newValue) }
    }
    public var executionCount: Int? {
        get { fields["execution_count"]?.integer }
        set { fields["execution_count"] = newValue.map { .number(Double($0)) } ?? .null }
    }
    public init(kind: String = "code", source: String = "") {
        fields = ["id": .string(UUID().uuidString.lowercased()), "metadata": .object([:]), "source": .string(source)]
        self.kind = kind
    }
    init(fields: [String: NotebookJSON]) { self.fields = fields }
}

public struct NotebookDocument: Equatable {
    public var fields: [String: NotebookJSON]
    public var cells: [NotebookCell]

    public init() {
        fields = ["nbformat": .number(4), "nbformat_minor": .number(5), "metadata": .object([
            "kernelspec": .object(["name": .string("python3"), "display_name": .string("Python 3"), "language": .string("python")])
        ])]
        cells = [NotebookCell()]
    }
    public init(data: Data) throws {
        guard let root = try JSONDecoder().decode(NotebookJSON.self, from: data).object,
              root["nbformat"]?.integer == 4, let values = root["cells"]?.array else {
            throw NotebookError.message("Se requiere un notebook Jupyter de formato 4 (.ipynb).")
        }
        fields = root
        fields.removeValue(forKey: "cells")
        var ids = Set<String>()
        cells = try values.map { value in
            guard var cell = value.object, let kind = cell["cell_type"]?.text, ["code", "markdown", "raw"].contains(kind), cell["source"]?.text != nil else {
                throw NotebookError.message("El notebook contiene una celda inválida.")
            }
            if let id = cell["id"]?.text, !id.isEmpty, ids.insert(id).inserted {} else {
                let id = UUID().uuidString.lowercased(); cell["id"] = .string(id); ids.insert(id)
            }
            return NotebookCell(fields: cell)
        }
    }
    public func data() throws -> Data {
        var root = fields
        root["cells"] = .array(cells.map { .object($0.fields) })
        // Adding cell ids upgrades older v4 files to the minor version that defines them.
        root["nbformat_minor"] = .number(Double(max(5, fields["nbformat_minor"]?.integer ?? 5)))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(NotebookJSON.object(root)) + Data([10])
    }
}

public enum NotebookError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
