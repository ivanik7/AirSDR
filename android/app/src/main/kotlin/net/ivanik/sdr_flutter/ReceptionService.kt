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
        private const val CHANNEL = "sdr_reception"
        private const val ID = 412
        private var current: ReceptionService? = null

        fun intent(ctx: Context, action: String, call: MethodCall): Intent =
            Intent(ctx, ReceptionService::class.java).setAction(action)
                .putExtra("frequency", call.argument<Int>("frequency") ?: 0)
                .putExtra("mode", call.argument<String>("mode") ?: "")

        fun updateIfRunning(call: MethodCall) {
            current?.update(call.argument<Int>("frequency") ?: 0,
                call.argument<String>("mode") ?: "")
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
            else -> requestStop() // never revive reception on a system restart
        }
        return START_NOT_STICKY
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
