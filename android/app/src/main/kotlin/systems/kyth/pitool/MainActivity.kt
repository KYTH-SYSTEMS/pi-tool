package systems.kyth.pitool

import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.view.WindowManager
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (not FlutterActivity) is required by local_auth so
// the biometric/credential prompt can attach to the activity.
class MainActivity : FlutterFragmentActivity() {
    // Tiny in-app file picker (Android SAF) exposed over a MethodChannel. It
    // lives in the app — not a plugin — so it uses the project's own Kotlin/AGP
    // and avoids the plugin version/KGP incompatibilities that broke file_picker.
    private val channelName = "pi_tool/filepicker"
    private var pending: MethodChannel.Result? = null
    private lateinit var picker: ActivityResultLauncher<Array<String>>

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // FLAG_SECURE blanks the recent-apps thumbnail and blocks screenshots /
        // screen recording — the app shows SSH keys and passwords on screen.
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
        // Must be registered before the activity is started.
        picker = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            val res = pending
            pending = null
            if (uri == null) {
                res?.success(null) // user cancelled
                return@registerForActivityResult
            }
            try {
                val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                if (bytes == null) {
                    res?.success(null)
                } else {
                    res?.success(mapOf("name" to queryName(uri), "bytes" to bytes))
                }
            } catch (e: Exception) {
                res?.error("read_failed", e.message, null)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "pickFile") {
                    if (pending != null) {
                        result.error("busy", "A pick is already in progress", null)
                    } else {
                        pending = result
                        picker.launch(arrayOf("*/*"))
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun queryName(uri: Uri): String {
        var name = "upload.bin"
        contentResolver.query(uri, null, null, null, null)?.use { c ->
            val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (idx >= 0 && c.moveToFirst()) {
                c.getString(idx)?.let { name = it }
            }
        }
        return name
    }
}
