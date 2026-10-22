import XCTest
@testable import Writers_Block

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

    /// The app's own pin check, bound to the production pin set in Info.plist:
    /// it accepts the Drive host's chain and refuses a chain from another CA.
    /// Removing the production pins makes the first half fail.
    func testProductionPinsAcceptTheDriveChainAndRefuseAnotherCA() async throws {
        let pins = PinnedTrust.pins(for: "www.googleapis.com")
        XCTAssertGreaterThanOrEqual(pins.count, 2)
        let drive = try await serverTrust(for: "www.googleapis.com")
        XCTAssertTrue(PinnedTrust.evaluate(drive, pins: pins), "the production pins no longer match the Drive host")
        let other = try await serverTrust(for: "github.com")
        XCTAssertFalse(PinnedTrust.evaluate(other, pins: pins), "a chain with no pinned CA was accepted")
        XCTAssertFalse(PinnedTrust.evaluate(drive, pins: []), "no pins must mean no trust")
    }

    /// The session the Drive client and sign-in use reaches the pinned hosts.
    func testPinnedSessionReachesTheDriveHosts() async throws {
        for host in ["www.googleapis.com", "oauth2.googleapis.com"] {
            do {
                let (_, response) = try await PinnedTrust.session.data(from: try XCTUnwrap(URL(string: "https://\(host)/")))
                XCTAssertNotNil(response as? HTTPURLResponse)
            } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .timedOut].contains(error.code) {
                throw XCTSkip("Offline: \(error)")
            }
        }
    }

    private func serverTrust(for host: String) async throws -> SecTrust {
        let capture = TrustCapture()
        let session = URLSession(configuration: .ephemeral, delegate: capture, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(from: try XCTUnwrap(URL(string: "https://\(host)/")))
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .timedOut].contains(error.code) {
            throw XCTSkip("Offline: \(error)")
        } catch {}
        return try XCTUnwrap(capture.trust, "no server trust for \(host)")
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

/// Records the server trust and refuses the connection; the test evaluates it.
private final class TrustCapture: NSObject, URLSessionDelegate, @unchecked Sendable {
    private(set) var trust: SecTrust?

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        trust = challenge.protectionSpace.serverTrust
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
