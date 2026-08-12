package systems.kyth.pitool

import android.content.Intent
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
    // Reject oversized files natively BEFORE reading them into memory, so a huge
    // pick can't OOM/ANR the app (Dart's kFileUploadLimit is 8 MB too).
    private val maxUploadBytes = 8L * 1024 * 1024
    private var pending: MethodChannel.Result? = null
    private lateinit var picker: ActivityResultLauncher<Array<String>>

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Start SECURE, always. Dart relaxes this per screen via the
        // "pi_tool/secure" channel below — but only after it is running, so a
        // slow start, a crash or a broken channel can never expose a password.
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
                val size = querySize(uri)
                if (size != null && size > maxUploadBytes) {
                    res?.error("too_large", "Datei zu groß (max 8 MB).", null)
                    return@registerForActivityResult
                }
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
                        // On launch failure, don't leave `pending` set (that would
                        // wedge every future pick with "busy") and fail the call.
                        try {
                            picker.launch(arrayOf("*/*"))
                        } catch (e: Exception) {
                            pending = null
                            result.error("launch_failed", e.message, null)
                        }
                    }
                } else {
                    result.notImplemented()
                }
            }

        // Screenshots: blocked only where credentials can be on screen. Blocking
        // the whole app also blocked users from showing it to anyone — and word
        // of mouth is this app's only distribution. Handler runs on the UI
        // thread, so touching the window here is safe.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pi_tool/secure")
            .setMethodCallHandler { call, result ->
                if (call.method == "setSecure") {
                    val secure = call.argument<Boolean>("secure") ?: true
                    if (secure) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }

        // Separate channel: open another installed app (e.g. Tailscale) so the
        // user can toggle the phone-side VPN. We can only OPEN it — Android
        // forbids one app from enabling another's VPN. Falls back to a URL
        // (Play Store) when the app isn't installed.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pi_tool/launcher")
            .setMethodCallHandler { call, result ->
                if (call.method == "openApp") {
                    val pkg = call.argument<String>("package")
                    val fallbackUrl = call.argument<String>("fallbackUrl")
                    val launch = pkg?.let { packageManager.getLaunchIntentForPackage(it) }
                    if (launch != null) {
                        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(launch)
                        result.success(true) // the app itself opened
                    } else if (fallbackUrl != null) {
                        try {
                            startActivity(
                                Intent(Intent.ACTION_VIEW, Uri.parse(fallbackUrl))
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                            )
                        } catch (_: Exception) {
                        }
                        result.success(false) // not installed → fallback used
                    } else {
                        result.success(false)
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

    private fun querySize(uri: Uri): Long? {
        var size: Long? = null
        contentResolver.query(uri, null, null, null, null)?.use { c ->
            val idx = c.getColumnIndex(OpenableColumns.SIZE)
            if (idx >= 0 && c.moveToFirst() && !c.isNull(idx)) size = c.getLong(idx)
        }
        return size
    }
}
