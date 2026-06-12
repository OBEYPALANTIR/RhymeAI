package com.rhymeai.app

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.IOException
import java.net.URL
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLException

/**
 * Smoke-checks that the certificate pins in res/xml/network_security_config.xml
 * still match what the AI provider endpoints actually serve. A pin mismatch
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
