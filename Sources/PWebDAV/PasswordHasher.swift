import CryptoKit
import Foundation

enum PasswordHasher {
    static func digest(username: String, password: String) -> String {
        let input = "\(username):PWebDAV:\(password)"
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
