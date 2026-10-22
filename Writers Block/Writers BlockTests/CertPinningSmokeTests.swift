import CryptoKit
import XCTest

/// Live smoke test for the ATS declarative certificate pins (NSPinnedDomains)
/// declared in Writers-Block-Info.plist.
///
/// Unit tests run inside the host app, so the host's Info.plist ATS pinning
/// applies to URLSession calls made here. For each pinned AI provider domain
/// we make a plain GET and assert that any failure is NOT a TLS trust failure
/// (which is what a pin mismatch produces). HTTP-level errors (404/401/etc.)
/// are fine — only the TLS handshake outcome matters.
///
/// Tests self-skip when offline. If a domain fails with a trust error, the
/// provider's chain no longer matches the pinned CA set — capture the error
/// and re-verify the chain before touching the pins (and keep Android's
/// network_security_config.xml in sync).
final class CertPinningSmokeTests: XCTestCase {
    private static let pinnedDomains = [
        "generativelanguage.googleapis.com",
        "api.openai.com",
        "api.anthropic.com",
        "www.googleapis.com",
        "oauth2.googleapis.com",
    ]

    func testGeminiDomainPassesPinnedTrustEvaluation() async throws {
        try await verifyPinnedDomain("generativelanguage.googleapis.com")
    }

    func testOpenAIDomainPassesPinnedTrustEvaluation() async throws {
        try await verifyPinnedDomain("api.openai.com")
    }

    func testAnthropicDomainPassesPinnedTrustEvaluation() async throws {
        try await verifyPinnedDomain("api.anthropic.com")
    }

    func testDriveBackupDomainPassesPinnedTrustEvaluation() async throws {
        try await verifyPinnedDomain("www.googleapis.com")
    }

    func testOAuthTokenDomainPassesPinnedTrustEvaluation() async throws {
        try await verifyPinnedDomain("oauth2.googleapis.com")
    }

    /// The pin check itself must fail closed: a session that pins identities the
    /// Drive host does not present is refused at the TLS layer, with no fallback
    /// to system trust. (ATS's own pins cannot be swapped inside a test, so this
    /// uses an isolated session with its own pinning delegate.)
    func testDriveHostIsRejectedWhenNoPinnedIdentityMatches() async throws {
        let delegate = MismatchedPinsDelegate(pins: [String(repeating: "A", count: 43) + "="])
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://www.googleapis.com/")))
        request.timeoutInterval = 30

        do {
            _ = try await session.data(for: request)
            XCTFail("A chain with no pinned identity was accepted")
        } catch let error as URLError where error.code == .cancelled {
            XCTAssertEqual(delegate.rejection, "no certificate in the chain matches a pinned identity")
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .timedOut].contains(error.code) {
            throw XCTSkip("Offline; skipping the pin rejection check: \(error)")
        }
    }

    private func verifyPinnedDomain(_ domain: String) async throws {
        let url = try XCTUnwrap(URL(string: "https://\(domain)/"))
        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
            // Any HTTP status means the TLS handshake (and the pin check)
            // succeeded; the endpoint just doesn't serve GET / unauthenticated.
            print("CERT_PIN_SMOKE domain=\(domain) status=\(httpResponse.statusCode)")
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw XCTSkip("Offline; skipping live pin check for \(domain): \(error)")
            case .serverCertificateUntrusted,
                 .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid,
                 .secureConnectionFailed,
                 .clientCertificateRejected,
                 .cancelled:
                XCTFail(
                    "TLS trust failure for pinned domain \(domain) — possible pin mismatch. "
                        + "Error: \(error) userInfo: \(error.userInfo)"
                )
            default:
                // Non-TLS transport errors (timeouts, DNS hiccups) are not pin
                // failures; surface them as skips so the suite stays honest.
                throw XCTSkip("Non-TLS network error for \(domain): \(error)")
            }
        }
    }
}

/// Pins by SHA-256 of each certificate in the chain; never defers to system trust.
private final class MismatchedPinsDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let pins: Set<String>
    private(set) var rejection: String?

    init(pins: Set<String>) { self.pins = pins }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else {
            rejection = "no server trust to evaluate"
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let presented = chain.map { Data(SHA256.hash(data: SecCertificateCopyData($0) as Data)).base64EncodedString() }
        if presented.contains(where: pins.contains) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            rejection = "no certificate in the chain matches a pinned identity"
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
