import CryptoKit
import Foundation
import Security

/// The Drive and OAuth hosts' certificate pins, checked in the app as well as by
/// ATS. The pin set is the one in Info.plist `NSPinnedDomains`; a host with no
/// pins, a chain the system does not trust, or a chain with no pinned CA is
/// refused (no fallback to system trust alone).
enum PinnedTrust {
    /// The session the Drive client and the Google sign-in requests use.
    static let session = URLSession(configuration: .default, delegate: PinningSessionDelegate(), delegateQueue: nil)

    /// SPKI SHA-256 (base64) pins for `host` from Info.plist.
    nonisolated static func pins(for host: String, info: [String: Any]? = Bundle.main.infoDictionary) -> Set<String> {
        guard let ats = info?["NSAppTransportSecurity"] as? [String: Any],
              let domains = ats["NSPinnedDomains"] as? [String: Any],
              let entry = domains[host] as? [String: Any],
              let identities = entry["NSPinnedCAIdentities"] as? [[String: Any]] else { return [] }
        return Set(identities.compactMap { $0["SPKI-SHA256-BASE64"] as? String })
    }

    /// True only when the system trusts the chain and a certificate in it has a pinned key.
    nonisolated static func evaluate(_ trust: SecTrust, pins: Set<String>) -> Bool {
        guard !pins.isEmpty, SecTrustEvaluateWithError(trust, nil),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return false }
        return chain.contains { spkiSHA256($0).map(pins.contains) ?? false }
    }

    /// Base64 SHA-256 of the certificate's SubjectPublicKeyInfo, as the pins are written.
    nonisolated static func spkiSHA256(_ certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              let type = attributes[kSecAttrKeyType] as? String,
              let bits = attributes[kSecAttrKeySizeInBits] as? Int,
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let header = spkiHeader(type: type, bits: bits) else { return nil }
        return Data(SHA256.hash(data: header + raw)).base64EncodedString()
    }

    /// The ASN.1 prefix that turns the raw key into a SubjectPublicKeyInfo.
    nonisolated private static func spkiHeader(type: String, bits: Int) -> Data? {
        let rsa = kSecAttrKeyTypeRSA as String
        let ec = kSecAttrKeyTypeECSECPrimeRandom as String
        let hex: String
        switch (type, bits) {
        case (rsa, 2048): hex = "30820122300d06092a864886f70d01010105000382010f00"
        case (rsa, 4096): hex = "30820222300d06092a864886f70d01010105000382020f00"
        case (ec, 256): hex = "3059301306072a8648ce3d020106082a8648ce3d030107034200"
        case (ec, 384): hex = "3076301006072a8648ce3d020106052b81040022036200"
        default: return nil
        }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }
}

final class PinningSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if PinnedTrust.evaluate(trust, pins: PinnedTrust.pins(for: challenge.protectionSpace.host)) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
