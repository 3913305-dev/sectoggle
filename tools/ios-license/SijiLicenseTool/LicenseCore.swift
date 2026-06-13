import CryptoKit
import Foundation

enum LicenseError: LocalizedError {
    case invalidDeviceCode(String)

    var errorDescription: String? {
        switch self {
        case .invalidDeviceCode(let msg):
            return msg
        }
    }
}

struct DeviceInfo {
    let name: String
    let plate: String
}

/// 与中邮司机帮 Android（LocationBypassHelper + gen_license.py）一致
enum LicenseCore {
    private static let routeStepM = 25.0
    private static let fenceJitterMaxM = 35.0
    private static let driveSpeedMinMs = 60.0 / 3.6
    private static let fenceSpeedMaxMs = 8
    private static let licenseFragA = "siji-sec"
    private static let licenseFragB = "fake-loc-hub-v2"
    private static let licenseFragC = "geo|geo_zddm|0.0005"
    private static let b32 = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static var coreKeyPrefixHex: String {
        deriveCoreKey().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    enum CardPlan: String, CaseIterable, Identifiable {
        case month = "月卡"
        case quarter = "季卡"
        case year = "年卡"

        var id: String { rawValue }

        var months: Int {
            switch self {
            case .month: return 1
            case .quarter: return 3
            case .year: return 12
            }
        }

        func expiryDate(from base: Date = Date()) -> Date {
            Calendar(identifier: .gregorian).date(byAdding: .month, value: months, to: base) ?? base
        }
    }

    static func parseDeviceCode(_ code: String) throws -> DeviceInfo {
        let packed = b32Decode(extractB32Payload(code))
        guard packed.count > 6 else {
            throw LicenseError.invalidDeviceCode("设备码长度无效，请点安卓面板「复制设备码」重新复制")
        }

        let cipher = packed.dropLast(6)
        let mac = packed.suffix(6)
        let key = deriveCoreKey()
        let expect = hmacSha256(key: key, data: Data(cipher) + Data("dc-v1".utf8)).prefix(6)
        guard mac.elementsEqual(expect) else {
            throw LicenseError.invalidDeviceCode(
                "设备码校验失败：密钥不匹配或复制不完整（指纹 \(coreKeyPrefixHex)）"
            )
        }

        guard let plain = String(data: xorStream(data: Data(cipher), key: key), encoding: .utf8) else {
            throw LicenseError.invalidDeviceCode("设备码内容无法解码")
        }
        let (name, plate) = try parseV1Payload(plain)
        return DeviceInfo(name: name, plate: plate)
    }

    private static func extractB32Payload(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let dashVariants = ["–", "—", "−", "‐", "‑", "‒", "―", "－"]
        for d in dashVariants {
            text = text.replacingOccurrences(of: d, with: "-")
        }
        text = text.replacingOccurrences(of: " ", with: "")
        if let range = text.range(of: "DC1") {
            text = String(text[range.upperBound...])
            if text.hasPrefix("-") {
                text = String(text.dropFirst())
            }
        }
        return text.filter { "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".contains($0) }
    }

    private static func parseV1Payload(_ plain: String) throws -> (String, String) {
        guard plain.hasPrefix("V1|") else {
            throw LicenseError.invalidDeviceCode("设备码内容无效（非 V1 格式，请确认是安卓 DC1 设备码）")
        }
        let rest = String(plain.dropFirst(3))
        let sub = rest.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard sub.count >= 2 else {
            throw LicenseError.invalidDeviceCode("设备码内容无效（字段不完整，请重新复制完整设备码）")
        }
        return (sub[0], sub[1])
    }

    static func generateActivation(info: DeviceInfo, plan: CardPlan) -> (code: String, expiryYmd: Int) {
        let expiry = plan.expiryDate()
        let expiryYmd = ymd(from: expiry)
        let code = buildActivation(name: info.name, plate: info.plate, expiry: expiry)
        return (code, expiryYmd)
    }

    static func ymd(from date: Date) -> Int {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    static func formatYmd(_ ymd: Int) -> String {
        let y = ymd / 10000
        let m = (ymd / 100) % 100
        let d = ymd % 100
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    private static func deriveCoreKey() -> Data {
        let speedPart = Int(driveSpeedMinMs * 1000)
        let xorPart = fenceSpeedMaxMs ^ 0x5A3C
        let seed = [
            licenseFragA,
            String(format: "%.3f", routeStepM),
            String(format: "%.1f", fenceJitterMaxM),
            licenseFragB,
            licenseFragC,
            String(speedPart),
            String(xorPart),
        ].joined(separator: "|")
        return Data(SHA256.hash(data: Data(seed.utf8)))
    }

    private static func buildActivation(name: String, plate: String, expiry: Date) -> String {
        let expiryYmd = ymd(from: expiry)
        let signInput = Data("V1|\(name)|\(plate)|\(expiryYmd)".utf8)
        let key = deriveCoreKey()
        let sig = hmacSha256(key: key, data: signInput).prefix(10)
        var packed = Data()
        var be = UInt32(expiryYmd).bigEndian
        withUnsafeBytes(of: &be) { packed.append(contentsOf: $0) }
        packed.append(sig)
        return "AK1-" + formatGroups(b32Encode(packed))
    }

    private static func hmacSha256(key: Data, data: Data) -> Data {
        let sym = SymmetricKey(data: key)
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: sym))
    }

    private static func expandStream(key: Data, length: Int) -> Data {
        var out = Data()
        var counter = 0
        while out.count < length {
            let chunk = hmacSha256(key: key, data: Data("lb-stream-\(counter)".utf8))
            out.append(chunk)
            counter += 1
        }
        return out.prefix(length)
    }

    private static func xorStream(data: Data, key: Data) -> Data {
        let stream = expandStream(key: key, length: data.count)
        return Data(zip(data, stream).map { $0 ^ $1 })
    }

    private static func b32Encode(_ data: Data) -> String {
        var buffer = 0
        var bits = 0
        var out = ""
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(b32[(buffer >> bits) & 31])
            }
        }
        if bits > 0 {
            out.append(b32[(buffer << (5 - bits)) & 31])
        }
        return out
    }

    private static func b32Decode(_ encoded: String) -> Data {
        let filtered = encoded.uppercased().filter { "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".contains($0) }
        var buffer = 0
        var bits = 0
        var out = Data()
        for ch in filtered {
            guard let idx = b32.firstIndex(of: ch) else { continue }
            buffer = (buffer << 5) | idx
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xFF))
            }
        }
        return out
    }

    private static func formatGroups(_ raw: String) -> String {
        stride(from: 0, to: raw.count, by: 4).map { i in
            let start = raw.index(raw.startIndex, offsetBy: i)
            let end = raw.index(start, offsetBy: min(4, raw.count - i), limitedBy: raw.endIndex) ?? raw.endIndex
            return String(raw[start..<end])
        }.joined(separator: "-")
    }
}
