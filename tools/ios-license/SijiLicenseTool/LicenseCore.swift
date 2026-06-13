import CryptoKit
import Foundation

enum LicenseError: LocalizedError {
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let msg):
            return msg
        }
    }
}

struct DeviceInfo {
    let uuid: String
    let shortCode: String
}

enum LicenseCore {
  /// 与 SecToggle / tools/SecLicense 一致
    static let defaultSecret = "SecToggle-License-2026-ChangeMe"

    private static let uuidPattern = try! NSRegularExpression(
        pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
    )

    enum CardPlan: String, CaseIterable, Identifiable {
        case month = "月卡"
        case quarter = "季卡"
        case year = "年卡"

        var id: String { rawValue }

        var validDays: Int {
            switch self {
            case .month: return 30
            case .quarter: return 90
            case .year: return 365
            }
        }
    }

    static func parseDeviceInput(_ raw: String) throws -> DeviceInfo {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased().hasPrefix("DC1") {
            throw LicenseError.invalidInput(
                "这是 Android DC1 设备码。SecToggle 请粘贴 SEC 面板「复制 UUID」的内容（形如 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx）"
            )
        }
        let uuid = try normalizeUUID(trimmed)
        return DeviceInfo(uuid: uuid, shortCode: deviceCodeShort(uuid))
    }

    static func generateActivation(uuid: String, plan: CardPlan) throws -> (code: String, expiryYmd: String) {
        let norm = try normalizeUUID(uuid)
        let expiry = expiryFromDays(plan.validDays)
        guard let code = generateCode(uuid: norm, expiryYmd: expiry) else {
            throw LicenseError.invalidInput("生成失败")
        }
        return (code, expiry)
    }

    static func normalizeUUID(_ raw: String) throws -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: " ", with: "")
        s = s.replacingOccurrences(of: "\n", with: "")
        s = s.replacingOccurrences(of: "\r", with: "")

        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        if uuidPattern.firstMatch(in: s, range: range) != nil {
            return s.lowercased()
        }

        let hex = s.filter { $0.isHexDigit }
        guard hex.count == 32 else {
            throw LicenseError.invalidInput(
                "请输入 SecToggle SEC 面板复制的 UUID（36 位带连字符，或 32 位十六进制）"
            )
        }
        let lower = hex.lowercased()
        return "\(lower.prefix(8))-\(lower.dropFirst(8).prefix(4))-\(lower.dropFirst(12).prefix(4))-\(lower.dropFirst(16).prefix(4))-\(lower.dropFirst(20))"
    }

    static func deviceCodeShort(_ uuid: String) -> String {
        let norm = (try? normalizeUUID(uuid)) ?? uuid.lowercased()
        let digest = SHA256.hash(data: Data(norm.utf8))
        let hex = digest.prefix(6).map { String(format: "%02X", $0) }.joined()
        return "\(hex.prefix(4))-\(hex.dropFirst(4).prefix(4))-\(hex.dropFirst(8).prefix(4))"
    }

    static func expiryFromDays(_ days: Int) -> String {
        let d = max(days, 1)
        let date = Calendar.current.date(byAdding: .day, value: d, to: Date()) ?? Date()
        return ymdCompact(from: date)
    }

    static func formatExpiryDisplay(_ yyyymmdd: String) -> String {
        guard yyyymmdd.count == 8 else { return yyyymmdd }
        let y = yyyymmdd.prefix(4)
        let m = yyyymmdd.dropFirst(4).prefix(2)
        let d = yyyymmdd.suffix(2)
        return "\(y)-\(m)-\(d)"
    }

    private static func generateCode(uuid: String, expiryYmd: String) -> String? {
        guard expiryYmd.count == 8, expiryYmd.allSatisfy(\.isNumber) else { return nil }
        let payload = "\(uuid)|\(expiryYmd)"
        let mac = hmacSha256(key: Data(defaultSecret.utf8), data: Data(payload.utf8))
        let hex = mac.prefix(8).map { String(format: "%02X", $0) }.joined()
        return "\(formatGroups(hex))-\(expiryYmd)"
    }

    private static func ymdCompact(from date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func hmacSha256(key: Data, data: Data) -> Data {
        let sym = SymmetricKey(data: key)
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: sym))
    }

    private static func formatGroups(_ hex16: String) -> String {
        let h = hex16.uppercased().filter { $0.isHexDigit }
        guard h.count >= 16 else { return "" }
        return stride(from: 0, to: 16, by: 4).map { i in
            let start = h.index(h.startIndex, offsetBy: i)
            let end = h.index(start, offsetBy: 4)
            return String(h[start..<end])
        }.joined(separator: "-")
    }
}
