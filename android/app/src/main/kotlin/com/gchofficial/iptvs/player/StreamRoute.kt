package com.gchofficial.iptvs.player

import java.net.InetSocketAddress
import java.net.Proxy

/**
 * The proxy a **stream** of the current content kind is fetched through, as
 * resolved by Dart from Settings -> Proxy ("Streams: Live / Movies / Series").
 *
 * The route is per kind and per session, on purpose: it describes how the user
 * asked *this* video to be fetched, not how the app reaches its provider's API
 * (that is Dart's `HttpOverrides` and stays governed by the proxy mode itself).
 * A null route means direct, which is what every build did before the setting
 * existed.
 *
 * Both engines need the same answer expressed their own way: ExoPlayer's
 * `OkHttpDataSource` takes a [java.net.Proxy], mpv takes a URL-shaped
 * `http-proxy` value that spells the scheme out because the one option carries
 * HTTP and SOCKS proxies alike.
 */
data class StreamRoute(
    val host: String,
    val port: Int,
    /** `HTTP` or `SOCKS` — Android's `ProxyInfo` vocabulary. */
    val type: String = "HTTP",
) {
    val socks: Boolean get() = type.equals("SOCKS", ignoreCase = true)

    val endpoint: InetSocketAddress
        get() = InetSocketAddress.createUnresolved(host, port)

    val javaProxy: Proxy
        get() = Proxy(if (socks) Proxy.Type.SOCKS else Proxy.Type.HTTP, endpoint)

    val mpvUrl: String
        get() = (if (socks) "socks5://" else "http://") + "$host:$port"

    companion object {
        /**
         * Parses a route, failing soft to `null` (direct) for anything a
         * half-filled Custom proxy could send — the same rule the Dart side
         * applies, so an unusable address never sends the stream nowhere.
         */
        fun of(host: String?, port: Int, type: String? = null): StreamRoute? {
            val cleaned = host?.trim().orEmpty()
            if (cleaned.isEmpty() || port <= 0 || port > 65535) return null
            val kind = type?.trim().orEmpty()
            return StreamRoute(cleaned, port, if (kind.isEmpty()) "HTTP" else kind)
        }
    }
}
