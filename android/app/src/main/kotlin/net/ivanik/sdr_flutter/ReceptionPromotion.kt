// SPDX-License-Identifier: GPL-3.0-or-later
package net.ivanik.sdr_flutter

/**
 * Plain state machine for the N2 native-engine service handshake on MethodChannel
 * `sdr/background` (`promote`/`release`; see docs/native-n2-adr.md, "N2 close-out: Android
 * wiring and default engine"). Zero android.* imports: the Service supplies every side effect
 * (start the foreground/wake-lock/focus attempt, schedule/cancel a timeout, clean up) and
 * reports outcomes back through [onForegroundReady]/[onPromotionFailed]; this class only
 * decides when, how many times and with what outcome to reply, and whether `release` or an
 * ordered teardown needs to run cleanup. Fully testable on the plain JVM.
 *
 * States:
 *  - IDLE: nothing promoted, no attempt running.
 *  - PROMOTING: a `promote` call is waiting for the foreground+wake-lock+focus-ready signal.
 *  - PROMOTED: foreground service, wake lock and audio focus are all held.
 */
class ReceptionPromotion(
    private val attemptStart: () -> Unit,
    private val scheduleTimeout: (Runnable) -> Unit,
    private val cancelTimeout: (Runnable) -> Unit,
    private val requestCleanup: () -> Unit,
) {
    sealed class Outcome {
        object Success : Outcome()
        data class Failure(val reason: String) : Outcome()
    }

    private enum class State { IDLE, PROMOTING, PROMOTED }

    private var state = State.IDLE

    // Set once an ordered teardown (notification Stop / focus loss / USB detach) has started.
    // From that point this Service instance's PROMOTED/PROMOTING lifetime is owned by that
    // teardown; neither a new `promote` nor `release` may start a second one.
    private var stopping = false

    private val pending = mutableListOf<(Outcome) -> Unit>()
    private val timeoutRunnable = Runnable { onTimeout() }

    val isPromoted: Boolean get() = state == State.PROMOTED

    /** Called for every `promote` MethodChannel call, in call order. */
    fun requestPromotion(reply: (Outcome) -> Unit) {
        if (stopping) {
            reply(Outcome.Failure("teardown in progress"))
            return
        }
        when (state) {
            State.PROMOTED -> reply(Outcome.Success)
            State.PROMOTING -> pending += reply
            State.IDLE -> {
                state = State.PROMOTING
                pending += reply
                scheduleTimeout(timeoutRunnable)
                attemptStart()
            }
        }
    }

    /** The service reports startForeground + wake lock + AUDIOFOCUS_GAIN all held. */
    fun onForegroundReady() {
        if (state != State.PROMOTING) return // late/duplicate signal after failure, timeout or teardown
        cancelTimeout(timeoutRunnable)
        state = State.PROMOTED
        complete(Outcome.Success)
    }

    /** The service reports a hard failure while promoting (an exception from startForeground,
     * denied audio focus, or startForegroundService throwing). Returns whether this call
     * actually transitioned anything (false for a late/duplicate signal). */
    fun onPromotionFailed(reason: String): Boolean {
        if (state != State.PROMOTING) return false
        cancelTimeout(timeoutRunnable)
        state = State.IDLE
        complete(Outcome.Failure(reason))
        requestCleanup()
        return true
    }

    private fun onTimeout() {
        onPromotionFailed("timed out waiting for foreground service and audio focus")
    }

    /** An ordered teardown has started. A `promote` still waiting for readiness cannot
     * succeed; a PROMOTED state is left untouched here — the teardown owns tearing it down
     * through the existing ReceptionTeardown path, not through [requestCleanup]. */
    fun onTeardownStarted() {
        stopping = true
        onPromotionFailed("teardown in progress")
    }

    /** Decision for `release`: an idempotent no-op unless currently PROMOTED and no ordered
     * teardown already owns the shutdown, in which case cleanup is requested exactly once. */
    fun requestRelease() {
        if (stopping || !isPromoted) return
        state = State.IDLE
        requestCleanup()
    }

    private fun complete(outcome: Outcome) {
        val callbacks = pending.toList()
        pending.clear()
        callbacks.forEach { it(outcome) }
    }
}
