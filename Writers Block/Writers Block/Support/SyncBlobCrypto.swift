import CryptoKit
import Foundation
import CommonCrypto

enum SyncBlobCryptoError: Error, Equatable {
    case emptyPassphrase
    case invalidSaltLength
    case invalidIVLength
    case truncatedEnvelope
    case unrecognizedEnvelope
    case keyDerivationFailed
    case authenticationFailed
    case nonPortablePassphrase
}

enum SyncBlobCrypto {
    private static let magic = Data("RAI1".utf8)
    private static let saltByteCount = 16
    private static let ivByteCount = 12
    private static let tagByteCount = 16
    private static let keyByteCount = 32
    private static let pbkdf2Iterations = 210_000

    static func seal(_ plaintext: Data, passphrase: String) throws -> Data {
        let salt = randomData(count: saltByteCount)
        let iv = randomData(count: ivByteCount)
        return try seal(plaintext, passphrase: passphrase, salt: salt, iv: iv)
    }

    static func seal(_ plaintext: Data, passphrase: String, salt: Data, iv: Data) throws -> Data {
        try requirePortablePassphrase(passphrase)
        guard salt.count == saltByteCount else { throw SyncBlobCryptoError.invalidSaltLength }
        guard iv.count == ivByteCount else { throw SyncBlobCryptoError.invalidIVLength }

        let header = magic + salt + iv
        let key = try deriveKey(passphrase: passphrase, salt: salt)
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: header)
        return header + sealed.ciphertext + sealed.tag
    }

    static func open(_ envelope: Data, passphrase: String) throws -> Data {
        try requirePortablePassphrase(passphrase)
        let headerByteCount = magic.count + saltByteCount + ivByteCount
        guard envelope.count > headerByteCount + tagByteCount else {
            throw SyncBlobCryptoError.truncatedEnvelope
        }
        guard envelope.prefix(magic.count) == magic else {
            throw SyncBlobCryptoError.unrecognizedEnvelope
        }

        let saltStart = magic.count
        let ivStart = saltStart + saltByteCount
        let bodyStart = headerByteCount
        let tagStart = envelope.count - tagByteCount

        let salt = envelope[saltStart..<ivStart]
        let iv = envelope[ivStart..<bodyStart]
        let header = envelope[..<bodyStart]
        let ciphertext = envelope[bodyStart..<tagStart]
        let tag = envelope[tagStart...]

        let key = try deriveKey(passphrase: passphrase, salt: Data(salt))
        let nonce = try AES.GCM.Nonce(data: Data(iv))
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(ciphertext), tag: Data(tag))
        do {
            return try AES.GCM.open(sealedBox, using: key, authenticating: Data(header))
        } catch {
            throw SyncBlobCryptoError.authenticationFailed
        }
    }

    private static func requirePortablePassphrase(_ passphrase: String) throws {
        guard !passphrase.isEmpty else { throw SyncBlobCryptoError.emptyPassphrase }
        guard passphrase.unicodeScalars.allSatisfy({ (0x20...0x7E).contains(Int($0.value)) }) else {
            throw SyncBlobCryptoError.nonPortablePassphrase
        }
    }

    private static func deriveKey(passphrase: String, salt: Data) throws -> SymmetricKey {
        guard let passphraseData = passphrase.data(using: .utf8) else {
            throw SyncBlobCryptoError.keyDerivationFailed
        }
        var derived = Data(repeating: 0, count: keyByteCount)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                passphraseData.withUnsafeBytes { passphraseBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passphraseBytes.bindMemory(to: Int8.self).baseAddress,
                        passphraseData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(pbkdf2Iterations),
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyByteCount
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw SyncBlobCryptoError.keyDerivationFailed }
        return SymmetricKey(data: derived)
    }

    private static func randomData(count: Int) -> Data {
        var bytes = Data(repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.bindMemory(to: UInt8.self).baseAddress!)
        }
        precondition(status == errSecSuccess, "Secure random generation failed")
        return bytes
    }
}
