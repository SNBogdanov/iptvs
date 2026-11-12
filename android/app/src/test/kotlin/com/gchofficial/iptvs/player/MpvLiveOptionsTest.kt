package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MpvLiveOptionsTest {
    @Test
    fun `a raw ts url gets reconnect_at_eof`() {
        val value = MpvLiveOptions.streamLavfO(
            "http://portal.example/live/u/p/123.ts",
        )
        assertEquals(MpvLiveOptions.STREAM_LAVF_O_AT_EOF, value)
        assertTrue(value.contains("reconnect_at_eof=1"))
        assertTrue(value.contains("reconnect=1"))
        assertTrue(value.contains("reconnect_streamed=1"))
        assertTrue(value.contains("reconnect_delay_max=5"))
    }

    @Test
    fun `an extensionless live url gets reconnect_at_eof`() {
        assertEquals(
            MpvLiveOptions.STREAM_LAVF_O_AT_EOF,
            MpvLiveOptions.streamLavfO("http://portal.example:8080/u/p/123"),
        )
    }

    @Test
    fun `an hls manifest never gets reconnect_at_eof`() {
        // A finite manifest that reconnects at EOF never finishes probing, so
        // the stream would never open at all.
        for (url in listOf(
            "http://portal.example/live/u/p/123.m3u8",
            "https://portal.example/LIVE/U/P/123.M3U8?token=x",
            "http://portal.example/get.php?type=m3u8&id=7",
        )) {
            val value = MpvLiveOptions.streamLavfO(url)
            assertEquals(url, MpvLiveOptions.STREAM_LAVF_O, value)
            assertFalse(url, value.contains("reconnect_at_eof"))
        }
    }

    @Test
    fun `the base value is the at-eof value minus the flag`() {
        assertEquals(
            "${MpvLiveOptions.STREAM_LAVF_O},reconnect_at_eof=1",
            MpvLiveOptions.STREAM_LAVF_O_AT_EOF,
        )
        assertEquals(
            1,
            MpvLiveOptions.STREAM_LAVF_O_AT_EOF
                .split(",")
                .count { it == "reconnect=1" },
        )
    }

    @Test
    fun `hls detection is case-insensitive`() {
        assertTrue(MpvLiveOptions.isHls("HTTP://X/A.M3U8"))
        assertFalse(MpvLiveOptions.isHls("http://x/a.ts"))
        assertFalse(MpvLiveOptions.isHls("http://x/a"))
    }
}
