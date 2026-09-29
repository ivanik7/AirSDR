package net.ivanik.sdr_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Foreground lifetime for the Activity-independent Dart engine. The receiver and USB fd
 * remain in that engine; a partial wake lock keeps Dart DSP/AAudio running with screen off.
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
                frequency = intent.getIntExtra("frequency", 0)
                mode = intent.getStringExtra("mode") ?: ""
                try {
                    startForeground(ID, notification())
                    if (wakeLock?.isHeld != true) {
                        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
                            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:reception")
                            .also { it.acquire() }
                    }
                } catch (e: Exception) {
                    Log.e("ReceptionService", "Foreground start failed", e)
                    // startForegroundService() succeeded, but promotion failed later in
                    // onStartCommand. Tell Dart to stop USB/DSP instead of leaving a
                    // receiver running without a foreground service.
                    (application as SdrApplication).radioEngine?.let { engine ->
                        MethodChannel(engine.dartExecutor.binaryMessenger, "sdr/background")
                            .invokeMethod("serviceFailed", null)
                    }
                    stopSelf()
                }
            }
            else -> stopSelf() // never revive reception on a system restart
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
        if (engine == null) { stopSelf(); return }
        // If Dart cannot acknowledge Stop, kill this process to close USB/AAudio rather
        // than leaving an invisible, still-running receiver after the notification vanishes.
        val watchdog = Runnable { Process.killProcess(Process.myPid()) }
        handler.postDelayed(watchdog, 15000)
        MethodChannel(engine.dartExecutor.binaryMessenger, "sdr/background")
            .invokeMethod("stopReception", null, object : MethodChannel.Result {
                override fun success(result: Any?) { handler.removeCallbacks(watchdog); stopSelf() }
                override fun error(code: String, message: String?, details: Any?) {
                    handler.removeCallbacks(watchdog)
                    Process.killProcess(Process.myPid())
                }
                override fun notImplemented() {
                    handler.removeCallbacks(watchdog)
                    Process.killProcess(Process.myPid())
                }
            })
    }

    override fun onDestroy() {
        if (current === this) current = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }
}
