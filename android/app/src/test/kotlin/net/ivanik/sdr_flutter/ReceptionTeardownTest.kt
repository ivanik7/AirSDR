// SPDX-License-Identifier: GPL-3.0-or-later
package net.ivanik.sdr_flutter

import org.junit.Assert.assertEquals
import org.junit.Test

class ReceptionTeardownTest {
    @Test fun `stop waits for both native fd close and receiver acknowledgement`() {
        val events = mutableListOf<String>()
        var nativeDone: (() -> Unit)? = null
        var receiverDone: ((Boolean) -> Unit)? = null
        val stop = ReceptionTeardown(
            closeNative = { nativeDone = it; events += "native.request" },
            stopReceiver = { receiverDone = it; events += "receiver.request" },
            finish = { ok -> events += "finish:$ok" },
        )
        stop.requestStop()
        stop.requestStop()
        assertEquals(listOf("native.request", "receiver.request"), events)
        receiverDone!!(true)
        assertEquals(2, events.size)
        nativeDone!!()
        assertEquals("finish:true", events.last())
        nativeDone!!()
        assertEquals(3, events.size)
    }

    @Test fun `failure still waits for native teardown before reporting failure`() {
        var nativeDone: (() -> Unit)? = null
        var receiverDone: ((Boolean) -> Unit)? = null
        val events = mutableListOf<Boolean>()
        val stop = ReceptionTeardown({ nativeDone = it }, { receiverDone = it }, { events += it })
        stop.requestStop()
        receiverDone!!(false)
        assertEquals(emptyList<Boolean>(), events)
        nativeDone!!()
        assertEquals(listOf(false), events)
    }
}
