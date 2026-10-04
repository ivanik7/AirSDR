// SPDX-License-Identifier: GPL-3.0-or-later
package net.ivanik.sdr_flutter

/** Main-thread serialized convergence of notification/UI Stop, including an Activity-less
 * native receiver. Foreground and wake lock remain held until both paths acknowledge. */
internal class ReceptionTeardown(
    private val closeNative: (() -> Unit) -> Unit,
    private val stopReceiver: ((Boolean) -> Unit) -> Unit,
    private val finish: (Boolean) -> Unit,
) {
    private var started = false
    private var nativeDone = false
    private var receiverDone = false
    private var receiverOk = false
    private var finished = false

    fun requestStop() {
        if (started) return
        started = true
        closeNative { nativeDone = true; maybeFinish() }
        stopReceiver { ok -> receiverDone = true; receiverOk = ok; maybeFinish() }
    }

    private fun maybeFinish() {
        if (nativeDone && receiverDone && !finished) {
            finished = true
            finish(receiverOk)
        }
    }
}
