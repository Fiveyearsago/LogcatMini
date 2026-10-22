import Foundation
import CommonCrypto
import Security

/// Optional packet codec: type + UInt32 LE wrapped-key length + key + AES-CBC/PKCS7 data.
/// This format is application-specific, not a universal decoder for every field named s.
/// Keys are supplied by the user and never bundled or persisted.
public enum SPacketCodec {
    public static func importPublicKey(_ pem: String) throws -> SecKey {
        let base64 = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined().filter { !$0.isWhitespace }
        guard var data = Data(base64Encoded: base64), data.count <= 32_768 else { throw ReplayError("不是有效的 PEM / Base64 RSA 公钥。") }
        let children = try derChildren(data)
        if let bits = children.last, bits.0 == 3, bits.1.first == 0 { data = Data(bits.1.dropFirst()) }
        return try makeKey(data, privateKey: false)
    }
    public static func importPrivateKey(_ pem: String) throws -> SecKey {
        guard !pem.contains("ENCRYPTED") else { throw ReplayError("请使用未加口令的 PKCS#1 或 PKCS#8 PEM 私钥。") }
        let base64 = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
            .filter { !$0.isWhitespace }
        guard var data = Data(base64Encoded: base64), data.count <= 32_768 else { throw ReplayError("不是有效的 PEM / Base64 RSA 私钥。") }
        let fields = try derChildren(data)
        if fields.count >= 3, fields[1].0 == 0x30, fields[2].0 == 4 { data = fields[2].1 }
        return try makeKey(data, privateKey: true)
    }
    public static func encrypt(_ plain: String, publicKey: SecKey? = nil) throws -> String {
        guard plain.utf8.count <= 2 * 1_024 * 1_024 else { throw ReplayError("明文超过 2 MiB。") }
        var random = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw ReplayError("无法生成随机密钥。") }
        // Android generates 16 ASCII characters; keep that convention for wire compatibility.
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        let aesKey = Data(random.map { alphabet[Int($0) % alphabet.count] })
        let cipher = try aes(Data(plain.utf8), key: aesKey, encrypt: true)
        guard let rsa = publicKey else { throw ReplayError("请先导入与目标服务对应的 RSA 公钥；公开版不附带业务密钥。") }
        var error: Unmanaged<CFError>?
        guard let wrapped = SecKeyCreateEncryptedData(rsa, .rsaEncryptionPKCS1, aesKey as CFData, &error) as Data? else {
            throw ReplayError("RSA 加密失败。")
        }
        let length = UInt32(wrapped.count)
        var packet = Data([3, UInt8(truncatingIfNeeded: length), UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length >> 16), UInt8(truncatingIfNeeded: length >> 24)])
        packet.append(wrapped); packet.append(cipher)
        return packet.base64EncodedString()
    }
    public static func decrypt(_ value: String, privateKey: SecKey? = nil) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).filter { !$0.isWhitespace }
        guard clean.utf8.count <= 4 * 1_024 * 1_024, let data = Data(base64Encoded: clean), let type = data.first else { throw ReplayError("s 不是有效的 Base64 报文。") }
        let plain: Data
        switch type {
        case 1: plain = Data(data.dropFirst())
        case 2, 3:
            guard data.count >= 5 else { throw ReplayError("s 报文头不完整。") }
            let length = (0..<4).reduce(0) { $0 | Int(data[1 + $1]) << (8 * $1) }
            guard length > 0, length <= 16_384, data.count > 5 + length,
                  (data.count - 5 - length) % 16 == 0 else { throw ReplayError("s 密钥长度或 AES 数据长度无效。") }
            let wrapped = Data(data[5..<(5 + length)])
            let key: Data
            if type == 2 { key = wrapped }
            else {
                guard let privateKey else { throw ReplayError("此 s 是 RSA + AES（type 3），需要导入服务端对应的 RSA 私钥；客户端公钥只能加密。") }
                var error: Unmanaged<CFError>?
                guard let result = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionPKCS1, wrapped as CFData, &error) as Data? else {
                    throw ReplayError("RSA 解密失败：私钥不匹配或 s 已损坏。")
                }
                key = result
            }
            plain = try aes(Data(data.dropFirst(5 + length)), key: key, encrypt: false)
        default: throw ReplayError("不支持的 s 报文类型：\(type)。")
        }
        guard let text = String(data: plain, encoding: .utf8) else { throw ReplayError("解密结果不是 UTF-8 文本；当前支持 encodePacketBase64(String)，不支持 gzip 二进制报文。") }
        return text
    }
    private static func aes(_ data: Data, key: Data, encrypt: Bool) throws -> Data {
        guard key.count == 16 else { throw ReplayError("此协议要求 16 字节 AES 密钥。") }
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128), moved = 0
        let capacity = out.count
        let status = key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { input in
                CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count, keyBytes.baseAddress, input.baseAddress, data.count, &out, capacity, &moved)
            }
        }
        guard status == kCCSuccess else { throw ReplayError("AES 解密或加密失败：密钥或报文不正确。") }
        return Data(out.prefix(moved))
    }
    private static func makeKey(_ data: Data, privateKey: Bool) throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: privateKey ? kSecAttrKeyClassPrivate : kSecAttrKeyClassPublic, kSecAttrIsPermanent: false]
        guard let key = SecKeyCreateWithData(data as CFData, attrs as CFDictionary, &error) else { throw ReplayError("无法读取 RSA 密钥，请检查 PEM 格式。") }
        return key
    }
    private static func derChildren(_ data: Data) throws -> [(UInt8, Data)] {
        let bytes = Array(data)
        func element(_ cursor: inout Int, limit: Int) throws -> (UInt8, Data) {
            guard cursor + 2 <= limit else { throw ReplayError("RSA DER 数据不完整。") }
            let tag = bytes[cursor]; cursor += 1
            var length = Int(bytes[cursor]); cursor += 1
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard (1...4).contains(count), cursor + count <= limit else { throw ReplayError("RSA DER 长度无效。") }
                length = 0
                for _ in 0..<count { length = length << 8 | Int(bytes[cursor]); cursor += 1 }
            }
            guard length <= limit - cursor else { throw ReplayError("RSA DER 长度越界。") }
            let payload = Data(bytes[cursor..<(cursor + length)]); cursor += length
            return (tag, payload)
        }
        var cursor = 0
        let root = try element(&cursor, limit: bytes.count)
        guard root.0 == 0x30, cursor == bytes.count else { throw ReplayError("RSA DER 结构无效。") }
        let offset = bytes.count - root.1.count
        cursor = offset
        var fields: [(UInt8, Data)] = []
        while cursor < bytes.count { fields.append(try element(&cursor, limit: bytes.count)) }
        return fields
    }
}
