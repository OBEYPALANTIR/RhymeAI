package com.rhymeai.app

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.IOException
import java.net.URL
import java.security.KeyStore
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLException

/**
 * Smoke-checks that the certificate pins in res/xml/network_security_config.xml
 * still match what the AI provider and Google Drive backup endpoints actually serve. A pin mismatch
 * surfaces as an SSLHandshakeException during the handshake; any HTTP status
 * (even an auth-error body) means TLS made it through the pin set.
 *
 * Connectivity-type failures (DNS, no route, timeout) self-skip via Assume so
 * an offline device doesn't masquerade as a pinning regression. The app only
 * holds INTERNET, so connectivity is probed by outcome rather than through
 * ConnectivityManager (which would need ACCESS_NETWORK_STATE).
 */
@RunWith(AndroidJUnit4::class)
class CertPinningInstrumentedTest {

    @Test
    fun geminiEndpointHandshakesThroughPins() {
        assertTlsHandshakeSucceeds("generativelanguage.googleapis.com")
    }

    @Test
    fun openAiEndpointHandshakesThroughPins() {
        assertTlsHandshakeSucceeds("api.openai.com")
    }

    @Test
    fun anthropicEndpointHandshakesThroughPins() {
        assertTlsHandshakeSucceeds("api.anthropic.com")
    }

    @Test
    fun driveEndpointHandshakesThroughPins() {
        assertTlsHandshakeSucceeds("www.googleapis.com")
    }

    @Test
    fun googleRevokeEndpointHandshakesThroughPins() {
        assertTlsHandshakeSucceeds("oauth2.googleapis.com")
    }

    /**
     * example.com chains to SSL.com roots and shares the Drive pin set, which has no
     * expiration. The control handshake uses the plain system CA store (no pins) and
     * must succeed; through the app's config the same chain must fail pin verification.
     */
    @Test
    fun drivePinSetRejectsAnUnpinnedChain() {
        val systemCas = KeyStore.getInstance("AndroidCAStore").apply { load(null) }
        val trust = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(systemCas) }
        val unpinned = SSLContext.getInstance("TLS").apply { init(null, trust.trustManagers, null) }
        val control = URL("https://example.com/").openConnection() as HttpsURLConnection
        control.sslSocketFactory = unpinned.socketFactory
        control.connectTimeout = 10_000
        control.readTimeout = 10_000
        try {
            control.connect()
        } catch (e: SSLException) {
            fail("Control: example.com should validate against the system CAs without pins: $e")
        } catch (e: IOException) {
            assumeTrue("No network connectivity to example.com; skipping pin rejection test ($e).", false)
        } finally {
            control.disconnect()
        }

        val pinned = URL("https://example.com/").openConnection() as HttpsURLConnection
        pinned.connectTimeout = 10_000
        pinned.readTimeout = 10_000
        try {
            pinned.connect()
            fail("example.com handshook through the Drive pin set; it must be refused")
        } catch (e: SSLException) {
            val messages = generateSequence<Throwable>(e) { it.cause }.mapNotNull { it.message }.toList()
            assertTrue("Expected a pin verification failure, got $messages", messages.any { "Pin verification failed" in it })
            println("CERT_PINNING_REJECTED domain=example.com reason=pin")
        } finally {
            pinned.disconnect()
        }
    }

    private fun assertTlsHandshakeSucceeds(domain: String) {
        val connection = URL("https://$domain/").openConnection() as HttpsURLConnection
        connection.connectTimeout = 10_000
        connection.readTimeout = 10_000
        try {
            connection.connect()
            // Any status code is fine -- the pins only gate the TLS handshake.
            val status = runCatching { connection.responseCode }.getOrNull()
            println("CERT_PINNING_RESULT domain=$domain status=$status")
        } catch (e: SSLException) {
            fail("TLS handshake to $domain failed under certificate pinning: $e (cause: ${e.cause})")
        } catch (e: IOException) {
            // DNS failure, unreachable network, or timeout -- not a pin mismatch.
            assumeTrue("No network connectivity to $domain; skipping pin smoke test ($e).", false)
        } finally {
            connection.disconnect()
        }
    }
}
