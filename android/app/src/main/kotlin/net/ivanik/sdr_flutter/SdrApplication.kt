package net.ivanik.sdr_flutter

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

/** Owns one Dart engine across Activity recreation/removal while reception is active.
 * The service and Activity run in the same process; neither creates a second radio.
 */
class SdrApplication : Application() {
    var radioEngine: FlutterEngine? = null
        private set

    fun getOrCreateEngine(): FlutterEngine {
        radioEngine?.let { return it }
        val engine = FlutterEngine(this) // auto-registers pub plugins
        engine.plugins.add(UsbSdrPlugin())
        engine.plugins.add(ReceptionPlugin())
        engine.plugins.add(MediaStorePlugin())
        engine.plugins.add(RecordFolderPlugin())
        radioEngine = engine
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        return engine
    }
}
