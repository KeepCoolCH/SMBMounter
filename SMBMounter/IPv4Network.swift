import Foundation

struct IPv4Network: Sendable {
    let address: UInt32
    let mask: UInt32

    nonisolated init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let address = Self.parse(String(parts[0])),
              !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber),
              let prefix = Int(parts[1]), (0...32).contains(prefix) else { return nil }
        self.address = address
        mask = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
    }

    nonisolated func contains(_ ip: String) -> Bool {
        guard let value = Self.parse(ip) else { return false }
        return value & mask == address & mask
    }

    nonisolated private static func parse(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let byte = UInt8(part) else { return nil }
            value = value << 8 | UInt32(byte)
        }
        return value
    }
}
