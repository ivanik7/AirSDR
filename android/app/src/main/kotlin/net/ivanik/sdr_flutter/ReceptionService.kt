package net.ivanik.sdr_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Foreground lifetime for the Activity-independent radio engine. A partial wake lock keeps
 * reception running with the screen off; native USB/audio are released before this ends.
 */
class ReceptionService : Service() {
    companion object {
        const val START = "net.ivanik.sdr_flutter.START_RECEPTION"
        const val STOP_REQUEST = "net.ivanik.sdr_flutter.STOP_RECEPTION"
        const val OPEN_RECEIVE = "net.ivanik.sdr_flutter.OPEN_RECEIVE"
        const val PROMOTE = "net.ivanik.sdr_flutter.PROMOTE_RECEPTION"
        private const val CHANNEL = "sdr_reception"
        private const val ID = 412
        private const val PROMOTION_TIMEOUT_MS = 10_000L
        private var current: ReceptionService? = null

        /** `promote` calls queued while the service process is still starting (no [current]
         * instance exists yet); drained by the fresh instance's PROMOTE onStartCommand. */
        private data class QueuedPromotion(
            val frequency: Int,
            val mode: String,
            val callback: (ReceptionPromotion.Outcome) -> Unit,
        )
        private val pendingPromotions = mutableListOf<QueuedPromotion>()

        fun intent(ctx: Context, action: String, call: MethodCall): Intent =
            Intent(ctx, ReceptionService::class.java).setAction(action)
                .putExtra("frequency", call.argument<Int>("frequency") ?: 0)
                .putExtra("mode", call.argument<String>("mode") ?: "")

        fun updateIfRunning(call: MethodCall) {
            current?.update(call.argument<Int>("frequency") ?: 0,
                call.argument<String>("mode") ?: "")
        }

        /** A receiver-owned USB detach must end the foreground lifetime, even without UI. */
        fun stopIfRunning() { current?.requestStop() }

        /** `promote` on MethodChannel sdr/background: start the service if needed and reply
         * only after startForeground, the wake lock and AUDIOFOCUS_GAIN are all held, or with
         * PROMOTION_FAILED on any failure (see ReceptionPromotion for the exact semantics). */
        fun requestPromotion(
            ctx: Context,
            call: MethodCall,
            callback: (ReceptionPromotion.Outcome) -> Unit,
        ) {
            val hz = call.argument<Int>("frequency") ?: 0
            val demod = call.argument<String>("mode") ?: ""
            val svc = current
            if (svc != null) {
                svc.promote(hz, demod, callback)
                return
            }
            val queued = QueuedPromotion(hz, demod, callback)
            pendingPromotions += queued
            try {
                ContextCompat.startForegroundService(ctx, intent(ctx, PROMOTE, call))
            } catch (e: Exception) {
                pendingPromotions.remove(queued)
                callback(ReceptionPromotion.Outcome.Failure(e.message ?: "startForegroundService failed"))
            }
        }

        /** `release`: idempotent no-op (success) when no service instance is running. */
        fun requestRelease(callback: () -> Unit) {
            val svc = current
            if (svc == null) callback() else svc.release(callback)
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private val handler = Handler(Looper.getMainLooper())
    private var frequency = 0
    private var mode = ""
    private var stopping = false
    private var teardownComplete = false
    private var teardown: ReceptionTeardown? = null
    private var focusRequest: AudioFocusRequest? = null
    private var focusHeld = false
    private var promotion: ReceptionPromotion? = null
    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (change <= 0) handler.post { if (!stopping) requestStop() }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        current = this
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Приём AirSDR",
            NotificationManager.IMPORTANCE_LOW).apply {
            description = "Активный радиоприём"
            setSound(null, null)
        })
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            STOP_REQUEST -> requestStop()
            START -> {
                if (stopping) return START_NOT_STICKY
                frequency = intent.getIntExtra("frequency", 0)
                mode = intent.getStringExtra("mode") ?: ""
                try {
                    startForeground(ID, notification())
                    if (wakeLock?.isHeld != true) {
                        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
                            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:reception")
                            .also { it.acquire() }
                    }
                    if (!focusHeld && !acquireFocus()) {
                        throw IllegalStateException("Audio focus denied")
                    }
                } catch (e: Exception) {
                    Log.e("ReceptionService", "Foreground/audio start failed", e)
                    // startForegroundService() succeeded, but promotion failed later in
                    // onStartCommand. Tell Dart to stop USB/DSP instead of leaving a
                    // receiver running without a foreground service.
                    (application as SdrApplication).radioEngine?.let { engine ->
                        MethodChannel(engine.dartExecutor.binaryMessenger, "sdr/background")
                            .invokeMethod("serviceFailed", null)
                    }
                    requestStop()
                }
            }
            PROMOTE -> {
                val queued = drainPendingPromotions()
                queued.forEach { promote(it.frequency, it.mode, it.callback) }
            }
            else -> requestStop() // never revive reception on a system restart
        }
        return START_NOT_STICKY
    }

    /** Companion entry point for `promote` when this instance is already running, and also
     * used to drain calls queued while the process was still starting (see PROMOTE above). */
    fun promote(hz: Int, demod: String, callback: (ReceptionPromotion.Outcome) -> Unit) {
        frequency = hz
        mode = demod
        val p = ensurePromotion()
        // Already promoted: succeed immediately but refresh the notification with the new
        // frequency/mode, as the contract requires.
        if (p.isPromoted) getSystemService(NotificationManager::class.java).notify(ID, notification())
        p.requestPromotion(callback)
    }

    /** Companion entry point for `release`. Always replies immediately; cleanup (if any) runs
     * synchronously first. Never touches stopReception or native USB -- see the ADR. */
    fun release(callback: () -> Unit) {
        promotion?.requestRelease()
        callback()
    }

    private fun ensurePromotion(): ReceptionPromotion {
        promotion?.let { return it }
        val created = ReceptionPromotion(
            attemptStart = { attemptForegroundPromotion() },
            scheduleTimeout = { r -> handler.postDelayed(r, PROMOTION_TIMEOUT_MS) },
            cancelTimeout = { r -> handler.removeCallbacks(r) },
            requestCleanup = { cleanupPromotion() },
        )
        // Defensive: a teardown already in progress at the service level (stopping) must be
        // reflected immediately in a freshly created state machine too.
        if (stopping) created.onTeardownStarted()
        promotion = created
        return created
    }

    /** Side effects behind ReceptionPromotion's PROMOTING -> PROMOTED transition: acquire
     * startForeground, the partial wake lock and AUDIOFOCUS_GAIN, in that order. */
    private fun attemptForegroundPromotion() {
        try {
            startForeground(ID, notification())
            if (wakeLock?.isHeld != true) {
                wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:reception")
                    .also { it.acquire() }
            }
            if (!focusHeld && !acquireFocus()) {
                throw IllegalStateException("Audio focus denied")
            }
            promotion?.onForegroundReady()
        } catch (e: Exception) {
            Log.e("ReceptionService", "Native promotion failed", e)
            promotion?.onPromotionFailed(e.message ?: "promotion failed")
        }
    }

    /** Drops focus, wake lock and foreground and stops the service, for both a failed
     * promotion attempt and a `release` call. Never invokes stopReception or
     * UsbSdrPlugin.closeNativeStreams -- Dart already stopped/closed the native handle and
     * released the USB fd. */
    private fun cleanupPromotion() {
        releaseFocus()
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        // Mark the teardown clean so onDestroy (below) does not kill the process.
        teardownComplete = true
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun drainPendingPromotions(): List<QueuedPromotion> {
        val list = pendingPromotions.toList()
        pendingPromotions.clear()
        return list
    }

    private fun update(hz: Int, demod: String) {
        if (stopping || wakeLock?.isHeld != true) return
        frequency = hz
        mode = demod
        getSystemService(NotificationManager::class.java).notify(ID, notification())
    }

    private fun notification(): Notification {
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).setAction(OPEN_RECEIVE)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1,
            Intent(this, ReceptionService::class.java).setAction(STOP_REQUEST),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val mhz = "%.3f".format(java.util.Locale.US, frequency / 1000000.0)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_airsdr)
            .setContentTitle("AirSDR")
            .setContentText("$mhz МГц · $mode")
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Стоп", stop).build())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun requestStop() {
        if (stopping) return
        stopping = true
        // A promote() still waiting for readiness cannot succeed once an ordered teardown
        // (notification Stop / focus loss / USB detach) has started; a later `release` must
        // also see `stopping` and do nothing, letting this teardown finish uncontested.
        promotion?.onTeardownStarted()
        val engine = (application as SdrApplication).radioEngine
        // Never drop foreground/wakelock until BOTH the Dart controller and native USB/audio
        // owner have stopped and closed. A missing engine has no Dart receiver to await.
        val watchdog = Runnable { Process.killProcess(Process.myPid()) }
        handler.postDelayed(watchdog, 15000)
        teardown = ReceptionTeardown(
            closeNative = { done ->
                val plugin = usbPlugin()
                if (plugin == null) done() else plugin.closeNativeStreams(done)
            },
            stopReceiver = { done ->
                if (engine == null) done(true)
                else MethodChannel(engine.dartExecutor.binaryMessenger, "sdr/background")
                    .invokeMethod("stopReception", null, object : MethodChannel.Result {
                        override fun success(result: Any?) = done(true)
                        override fun error(code: String, message: String?, details: Any?) = done(false)
                        override fun notImplemented() = done(false)
                    })
            },
            finish = { ok ->
                handler.removeCallbacks(watchdog)
                if (!ok) Process.killProcess(Process.myPid())
                else {
                    teardownComplete = true
                    stopSelf()
                }
            },
        ).also { it.requestStop() }
    }

    private fun acquireFocus(): Boolean {
        val audio = getSystemService(AUDIO_SERVICE) as AudioManager
        val result = if (Build.VERSION.SDK_INT >= 26) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                .setOnAudioFocusChangeListener(focusListener).build()
            focusRequest = request
            audio.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            audio.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        }
        focusHeld = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        return focusHeld
    }

    private fun releaseFocus() {
        if (!focusHeld) return
        val audio = getSystemService(AUDIO_SERVICE) as AudioManager
        val request = focusRequest
        if (Build.VERSION.SDK_INT >= 26 && request != null) audio.abandonAudioFocusRequest(request)
        else {
            @Suppress("DEPRECATION")
            audio.abandonAudioFocus(focusListener)
        }
        focusRequest = null
        focusHeld = false
    }

    override fun onDestroy() {
        if (current === this) current = null
        // Forced service destruction (not the ordered Stop above) cannot await a main-thread
        // callback here. Closing the process is the only safe fallback against zombie audio.
        if (!teardownComplete) Process.killProcess(Process.myPid())
        releaseFocus()
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    private fun usbPlugin(): UsbSdrPlugin? =
        (application as SdrApplication).radioEngine?.plugins?.get(UsbSdrPlugin::class.java) as? UsbSdrPlugin
}
