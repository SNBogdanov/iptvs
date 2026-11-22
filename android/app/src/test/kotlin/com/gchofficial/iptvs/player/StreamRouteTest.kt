package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The stream route is the one thing between a user's proxy switch and a video
 * connection, and it is spoken by two engines in two vocabularies (a
 * [java.net.Proxy] and mpv's URL-shaped `http-proxy`). Every current and future
 * engine reads it through this object, so the conversions are pinned here.
 */
class StreamRouteTest {
    @Test
    fun `a half-filled route falls back to direct`() {
        // The same fail-soft rule as the Dart side: a Custom proxy the user has
        // not finished typing must never send the stream nowhere.
        assertNull(StreamRoute.of(null, 8888))
        assertNull(StreamRoute.of("", 8888))
        assertNull(StreamRoute.of("   ", 8888))
        assertNull(StreamRoute.of("proxy", 0))
        assertNull(StreamRoute.of("proxy", -1))
        assertNull(StreamRoute.of("proxy", 65536))
    }

    @Test
    fun `host whitespace is trimmed and the type defaults to HTTP`() {
        val route = StreamRoute.of("  192.168.1.4 ", 8888)
        assertEquals("192.168.1.4", route!!.host)
        assertEquals(8888, route.port)
        assertEquals("HTTP", route.type)
        assertEquals("http://192.168.1.4:8888", route.mpvUrl)
        assertEquals(java.net.Proxy.Type.HTTP, route.javaProxy.type())
    }

    @Test
    fun `a SOCKS proxy is SOCKS for both engines`() {
        val route = StreamRoute.of("proxy", 1080, "SOCKS")!!
        assertTrue(route.socks)
        assertEquals(java.net.Proxy.Type.SOCKS, route.javaProxy.type())
        // mpv spells the scheme out because the one option carries both kinds.
        assertEquals("socks5://proxy:1080", route.mpvUrl)
    }

    @Test
    fun `an unknown type stays HTTP rather than inventing a scheme`() {
        val route = StreamRoute.of("proxy", 8888, "WEIRD")!!
        assertEquals(java.net.Proxy.Type.HTTP, route.javaProxy.type())
        assertEquals("http://proxy:8888", route.mpvUrl)
    }

    @Test
    fun `an unresolvable host is still a valid route`() {
        // Provider addresses are resolved by the proxy, not by the app: creating
        // the socket must not block or throw on a host this device cannot see.
        val route = StreamRoute.of("iptv.example", 8888)!!
        assertEquals("iptv.example", route.endpoint.hostString)
        assertTrue(route.endpoint.isUnresolved)
    }
}
