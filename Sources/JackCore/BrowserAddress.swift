import Foundation

/// What the integrated browser opens for whatever the user types in its address bar.
public enum BrowserAddress {
    /// `localhost:3000` and `127.0.0.1` get http, other hosts https, and anything else becomes a search.
    public static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*://", options: .regularExpression) != nil { return URL(string: text) }
        if text.allSatisfy(\.isNumber), let port = Int(text), port > 0, port < 65536 { return URL(string: "http://localhost:\(port)") }
        let host = text.split(separator: "/").first.map(String.init) ?? text
        let local = host.hasPrefix("localhost") || host.hasPrefix("127.") || host.hasPrefix("0.0.0.0") || host.hasPrefix("[::1]")
            || host.hasSuffix(".local") || host.range(of: "^\\d+\\.\\d+\\.\\d+\\.\\d+(:\\d+)?$", options: .regularExpression) != nil
        if local { return URL(string: "http://" + text) }
        if !text.contains(" "), host.contains(".") { return URL(string: "https://" + text) }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url
    }
}
