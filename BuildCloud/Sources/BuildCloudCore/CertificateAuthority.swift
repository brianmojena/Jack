import Foundation
import Security
import SystemConfiguration

public enum CertificateAuthorityError: LocalizedError {
    case openssl(String)
    case importFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .openssl(let message): "openssl falló: \(message)"
        case .importFailed(let status): "No se pudo cargar el certificado del servidor (OSStatus \(status))."
        }
    }
}

/// A private certificate authority for serving HTTPS on the local network.
/// Each iPhone trusts the CA once (through a configuration profile); the server certificate it signs
/// is renewed on its own when it nears expiry or when the Mac's name or IPs change, without reinstalling anything.
///
/// Files live in `directory` (by default ~/Library/Application Support/BuildCloud/tls), never in the served folder.
public struct CertificateAuthority: Sendable {
    public let directory: URL
    /// Server certificates stay under Apple's 398-day limit for TLS certificates.
    static let serverValidityDays = 397
    static let renewalMargin: TimeInterval = 30 * 24 * 3600
    static let p12Password = "buildcloud"

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BuildCloud/tls", isDirectory: true)
    }

    public init(directory: URL = CertificateAuthority.defaultDirectory) {
        self.directory = directory
    }

    var caKey: URL { directory.appendingPathComponent("ca.key") }
    var caCert: URL { directory.appendingPathComponent("ca.pem") }
    var serverKey: URL { directory.appendingPathComponent("server.key") }
    var serverCert: URL { directory.appendingPathComponent("server.pem") }
    var serverP12: URL { directory.appendingPathComponent("server.p12") }
    var serverNames: URL { directory.appendingPathComponent("server-names.txt") }

    // MARK: - Public API

    /// Makes sure the CA and a current server certificate for `names` exist, and returns the server identity.
    public func identity(for names: ServerNames) throws -> SecIdentity {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try ensureCA()
        if needsNewServerCertificate(for: names) { try issueServerCertificate(for: names) }
        return try loadIdentity()
    }

    /// The CA certificate in DER form, for the configuration profile and the .crt download.
    public func caCertificateDER() throws -> Data {
        try Self.der(fromPEM: String(contentsOf: caCert, encoding: .utf8))
    }

    /// SHA-256 fingerprint of the CA, shown so people can check what they are trusting.
    public func caFingerprint() throws -> String {
        let output = try openssl(["x509", "-in", caCert.path, "-noout", "-fingerprint", "-sha256"])
        return output.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// An iOS configuration profile that installs the CA as a trusted root.
    public func mobileConfig() throws -> Data {
        let der = try caCertificateDER()
        let name = try caCommonName()
        let profileID = "dev.jack.buildcloud.ca.\(Self.stableID(der))"
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": profileID,
            "PayloadUUID": Self.uuid(from: der, salt: "profile"),
            "PayloadDisplayName": "BuildCloud",
            "PayloadDescription": "Permite instalar las builds de BuildCloud desde la red local.",
            "PayloadOrganization": "BuildCloud",
            "PayloadContent": [[
                "PayloadType": "com.apple.security.root",
                "PayloadVersion": 1,
                "PayloadIdentifier": "\(profileID).root",
                "PayloadUUID": Self.uuid(from: der, salt: "root"),
                "PayloadDisplayName": name,
                "PayloadCertificateFileName": "BuildCloud-CA.cer",
                "PayloadContent": der,
            ] as [String: Any]],
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    // MARK: - CA

    func ensureCA() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: caKey.path), fm.fileExists(atPath: caCert.path) { return }
        let config = directory.appendingPathComponent("ca.cnf")
        try """
        [req]
        distinguished_name = dn
        [dn]
        [v3_ca]
        basicConstraints = critical, CA:TRUE, pathlen:0
        keyUsage = critical, keyCertSign, cRLSign
        subjectKeyIdentifier = hash
        """.write(to: config, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: config) }
        let host = ServerNames.localHostName ?? "Mac"
        try openssl(["req", "-x509", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "3650",
                     "-keyout", caKey.path, "-out", caCert.path, "-config", config.path, "-extensions", "v3_ca",
                     "-subj", "/O=BuildCloud/CN=BuildCloud CA (\(host))"])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: caKey.path)
        // A new CA invalidates any server certificate signed by an older one.
        for file in [serverKey, serverCert, serverP12, serverNames] { try? fm.removeItem(at: file) }
    }

    func caCommonName() throws -> String {
        let subject = try openssl(["x509", "-in", caCert.path, "-noout", "-subject"])
        return subject.components(separatedBy: "CN=").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "BuildCloud CA"
    }

    // MARK: - Server certificate

    func needsNewServerCertificate(for names: ServerNames) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: serverP12.path),
              let saved = try? String(contentsOf: serverNames, encoding: .utf8),
              saved == names.fingerprint,
              let expiry = try? serverCertificateExpiry() else { return true }
        return expiry.timeIntervalSinceNow < Self.renewalMargin
    }

    func serverCertificateExpiry() throws -> Date? {
        let output = try openssl(["x509", "-in", serverCert.path, "-noout", "-enddate"])
        let value = output.replacingOccurrences(of: "notAfter=", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "MMM d HH:mm:ss yyyy zzz"
        return formatter.date(from: value.replacingOccurrences(of: "  ", with: " "))
    }

    func issueServerCertificate(for names: ServerNames) throws {
        let fm = FileManager.default
        let config = directory.appendingPathComponent("server.cnf")
        let csr = directory.appendingPathComponent("server.csr")
        defer {
            try? fm.removeItem(at: config)
            try? fm.removeItem(at: csr)
        }
        let altNames = names.dns.map { "DNS:\($0)" } + names.ips.map { "IP:\($0)" }
        try """
        [req]
        distinguished_name = dn
        [dn]
        [v3_server]
        basicConstraints = critical, CA:FALSE
        keyUsage = critical, digitalSignature, keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = \(altNames.joined(separator: ", "))
        authorityKeyIdentifier = keyid
        subjectKeyIdentifier = hash
        """.write(to: config, atomically: true, encoding: .utf8)

        try openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256", "-keyout", serverKey.path,
                     "-out", csr.path, "-config", config.path, "-subj", "/O=BuildCloud/CN=\(names.dns.first ?? "localhost")"])
        try openssl(["x509", "-req", "-in", csr.path, "-CA", caCert.path, "-CAkey", caKey.path,
                     "-set_serial", "0x\(Self.randomSerial())", "-days", "\(Self.serverValidityDays)", "-sha256",
                     "-extfile", config.path, "-extensions", "v3_server", "-out", serverCert.path])
        try openssl(["pkcs12", "-export", "-inkey", serverKey.path, "-in", serverCert.path, "-certfile", caCert.path,
                     "-name", "BuildCloud", "-out", serverP12.path, "-passout", "pass:\(Self.p12Password)"])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: serverKey.path)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: serverP12.path)
        try names.fingerprint.write(to: serverNames, atomically: true, encoding: .utf8)
    }

    func loadIdentity() throws -> SecIdentity {
        let data = try Data(contentsOf: serverP12)
        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: Self.p12Password,
                                      kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else { throw CertificateAuthorityError.importFailed(status) }
        return identity as! SecIdentity
    }

    // MARK: - Helpers

    @discardableResult
    func openssl(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CertificateAuthorityError.openssl(String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: output, as: UTF8.self)
    }

    static func der(fromPEM pem: String) throws -> Data {
        let base64 = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: base64) else { throw CertificateAuthorityError.openssl("PEM no válido") }
        return data
    }

    static func randomSerial() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Deterministic identifiers so reinstalling the profile replaces the old one instead of duplicating it.
    static func stableID(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    static func uuid(from data: Data, salt: String) -> String {
        let a = stableID(data + Data(salt.utf8)), b = stableID(Data(salt.utf8) + data)
        let hex = (a + b).padding(toLength: 32, withPad: "0", startingAt: 0)
        let chars = Array(hex)
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(chars[$0]) }.joined(separator: "-").uppercased()
    }
}

/// The names the server certificate must cover: the Mac's Bonjour name and its IPv4 addresses.
public struct ServerNames: Equatable, Sendable {
    public var dns: [String]
    public var ips: [String]

    public init(dns: [String], ips: [String]) {
        self.dns = dns
        self.ips = ips
    }

    /// `<LocalHostName>.local`, `localhost` and every IPv4 address of the Mac.
    public static func current() -> ServerNames {
        var dns: [String] = []
        if let host = localHostName { dns.append("\(host).local".lowercased()) }
        dns.append("localhost")
        return ServerNames(dns: dns, ips: ["127.0.0.1"] + localIPv4Addresses())
    }

    var fingerprint: String { (dns + ips).joined(separator: ",") }

    /// The Bonjour host name, e.g. "MacBook-Air-de-Ruben".
    public static var localHostName: String? {
        SCDynamicStoreCopyLocalHostName(nil) as String?
    }

    /// Non-loopback IPv4 addresses, LAN interfaces (en*) first.
    public static func localIPv4Addresses() -> [String] {
        var result: [(name: String, ip: String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append((String(cString: entry.ifa_name), String(cString: host)))
        }
        let sorted = result.sorted { ($0.name.hasPrefix("en") ? 0 : 1, $0.name) < ($1.name.hasPrefix("en") ? 0 : 1, $1.name) }
        var seen = Set<String>()
        return sorted.map(\.ip).filter { seen.insert($0).inserted }
    }

    /// The address iPhones on the LAN should use: the Bonjour .local name, else the first IPv4.
    public static func preferredLANHost() -> String {
        if let host = localHostName { return "\(host).local".lowercased() }
        return localIPv4Addresses().first ?? "localhost"
    }
}
