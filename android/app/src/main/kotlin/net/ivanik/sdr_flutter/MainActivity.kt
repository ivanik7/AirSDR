package net.ivanik.sdr_flutter

import android.content.Context
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // An externally owned engine survives this Activity (including swipe from Recents).
    // UsbSdrPlugin stays attached to that engine, but detaches from this Activity.
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        (application as SdrApplication).getOrCreateEngine()

    override fun onPostResume() {
        super.onPostResume()
        openReceiveIfRequested(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        openReceiveIfRequested(intent)
    }

    private fun openReceiveIfRequested(intent: Intent?) {
        if (intent?.action != ReceptionService.OPEN_RECEIVE) return
        intent.action = Intent.ACTION_MAIN // consume once, not again after rotation
        flutterEngine?.let {
            MethodChannel(it.dartExecutor.binaryMessenger, "sdr/background")
                .invokeMethod("openReceive", null)
        }
    }
}
