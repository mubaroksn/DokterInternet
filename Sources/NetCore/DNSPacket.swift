import Foundation

/// Minimal DNS wire format: enough to send a query and read the header of the reply.
public enum DNSPacket {
    public static func query(id: UInt16, name: String, type: UInt16 = 1) -> Data {
        var d = Data()
        d.append(UInt8(id >> 8))
        d.append(UInt8(id & 0xFF))
        d.append(contentsOf: [0x01, 0x00])                    // flags: recursion desired
        d.append(contentsOf: [0x00, 0x01, 0, 0, 0, 0, 0, 0])  // 1 question, no other records
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8.prefix(63))
            d.append(UInt8(bytes.count))
            d.append(contentsOf: bytes)
        }
        d.append(0)
        d.append(UInt8(type >> 8))
        d.append(UInt8(type & 0xFF))
        d.append(contentsOf: [0x00, 0x01])                    // class IN
        return d
    }

    public struct Header: Sendable, Equatable {
        public var id: UInt16
        public var isResponse: Bool
        public var rcode: Int
        public var answerCount: Int
    }

    public static func parseHeader(_ data: Data) -> Header? {
        guard data.count >= 12 else { return nil }
        let b = [UInt8](data.prefix(12))
        return Header(
            id: UInt16(b[0]) << 8 | UInt16(b[1]),
            isResponse: b[2] & 0x80 != 0,
            rcode: Int(b[3] & 0x0F),
            answerCount: Int(b[6]) << 8 | Int(b[7])
        )
    }

    /// A reply counts as "answered" for NOERROR and NXDOMAIN; SERVFAIL/REFUSED count as failures.
    public static func isUsableReply(_ data: Data, expectedID: UInt16) -> Bool {
        guard let h = parseHeader(data), h.isResponse, h.id == expectedID else { return false }
        return h.rcode == 0 || h.rcode == 3
    }
}

public struct DNSProvider: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var servers: [String]
    public var note: String
    public var isCustom: Bool

    public init(name: String, servers: [String], note: String, isCustom: Bool = false) {
        self.name = name
        self.servers = servers
        self.note = note
        self.isCustom = isCustom
    }

    public static let presets: [DNSProvider] = [
        DNSProvider(name: "Cloudflare", servers: ["1.1.1.1", "1.0.0.1"], note: "Cepat dan menjaga privasi"),
        DNSProvider(name: "Google", servers: ["8.8.8.8", "8.8.4.4"], note: "Stabil, dipakai di mana-mana"),
        DNSProvider(name: "Quad9", servers: ["9.9.9.9", "149.112.112.112"], note: "Memblokir situs berbahaya"),
        DNSProvider(name: "AdGuard", servers: ["94.140.14.14", "94.140.15.15"], note: "Memblokir iklan & pelacak"),
        DNSProvider(name: "OpenDNS", servers: ["208.67.222.222", "208.67.220.220"], note: "Dari Cisco, ada filter phishing"),
    ]

    /// Domains used to time resolvers: popular (likely cached) plus local favourites.
    public static let testDomains = [
        "google.com", "youtube.com", "instagram.com", "whatsapp.net",
        "tokopedia.com", "shopee.co.id", "detik.com", "netflix.com",
    ]
}
