import CommonCrypto
import Foundation
import Security

enum PasswordHasher {
    private static let algorithm = "pbkdf2"
    private static let currentIterations = 310_000
    private static let maxSupportedIterations = 2_000_000
    private static let saltByteCount = 16
    private static let hashByteCount = 32

    static func digest(password: String) -> String {
        let salt = randomBytes(count: saltByteCount)
        let hash = deriveKey(password: password, salt: salt, iterations: currentIterations, keyByteCount: hashByteCount)
        return "\(algorithm)$\(currentIterations)$\(salt.hexEncodedString)$\(hash.hexEncodedString)"
    }

    static func verify(password: String, digest: String) -> Bool {
        guard let storedDigest = parse(digest) else { return false }
        let hash = deriveKey(
            password: password,
            salt: storedDigest.salt,
            iterations: storedDigest.iterations,
            keyByteCount: storedDigest.hash.count
        )
        return constantTimeEquals(Array(hash), Array(storedDigest.hash))
    }

    static func isSupportedDigest(_ digest: String) -> Bool {
        parse(digest) != nil
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        constantTimeEquals(Array(lhs.utf8), Array(rhs.utf8))
    }

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            preconditionFailure("Unable to generate password salt")
        }
        return Data(bytes)
    }

    private static func deriveKey(password: String, salt: Data, iterations: Int, keyByteCount: Int) -> Data {
        let passwordData = Data(password.utf8)
        var derivedKey = Data(count: keyByteCount)

        let status = derivedKey.withUnsafeMutableBytes { keyBuffer in
            salt.withUnsafeBytes { saltBuffer in
                passwordData.withUnsafeBytes { passwordBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        keyBuffer.bindMemory(to: UInt8.self).baseAddress,
                        keyByteCount
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            preconditionFailure("Unable to derive password hash")
        }

        return derivedKey
    }

    private static func parse(_ digest: String) -> StoredDigest? {
        let parts = digest.split(separator: "$", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0] == algorithm,
              let iterations = Int(parts[1]),
              iterations > 0,
              iterations <= maxSupportedIterations,
              let salt = Data(hexEncoded: String(parts[2])),
              !salt.isEmpty,
              let hash = Data(hexEncoded: String(parts[3])),
              !hash.isEmpty else {
            return nil
        }

        return StoredDigest(iterations: iterations, salt: salt, hash: hash)
    }

    private static func constantTimeEquals(_ lhsBytes: [UInt8], _ rhsBytes: [UInt8]) -> Bool {
        var difference = lhsBytes.count ^ rhsBytes.count
        let count = max(lhsBytes.count, rhsBytes.count)

        for index in 0..<count {
            let lhsByte = index < lhsBytes.count ? lhsBytes[index] : 0
            let rhsByte = index < rhsBytes.count ? rhsBytes[index] : 0
            difference |= Int(lhsByte ^ rhsByte)
        }

        return difference == 0
    }

    private struct StoredDigest {
        let iterations: Int
        let salt: Data
        let hash: Data
    }
}

private extension Data {
    init?(hexEncoded string: String) {
        guard string.count.isMultiple(of: 2) else { return nil }

        var bytes = [UInt8]()
        bytes.reserveCapacity(string.count / 2)

        var index = string.startIndex
        while index < string.endIndex {
            let nextIndex = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<nextIndex], radix: 16) else { return nil }
            bytes.append(byte)
            index = nextIndex
        }

        self = Data(bytes)
    }

    var hexEncodedString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
