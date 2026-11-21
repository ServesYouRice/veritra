package org.veritra.private_messenger

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The foreground service a screen share in a group call needs (B6,
 * docs/designs/B6-group-calls.md "Mobile and desktop constraints").
 *
 * Android 14 and later refuse MediaProjection unless a foreground service of
 * type `mediaProjection` runs, and refuse to start that service before the
 * user accepted the capture consent. Dart therefore asks for the consent
 * first (flutter_webrtc's requestCapturePermission), then calls "start" here,
 * and only then creates the screen track. "start" answers true only once
 * startForeground has succeeded, so a refusal (not allowed in this app state,
 * the type permission missing) stops the share before any capture exists.
 *
 * The service exists only while a share does. It shows one fixed notification
 * with no names (like I41) and is never started by a push or a wake job (D52).
 * Demo builds only: the BuildConfig flag is decided at build time, and the
 * manifest entry sits in the debug manifest, so a release build neither
 * declares nor starts it. The microphone and camera need no service while the
 * app is in the foreground (O5).
 */
class RoomCallService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val mediaProjection = intent?.getBooleanExtra(EXTRA_MEDIA_PROJECTION, false) ?: false
        val ok = try {
            startForegroundNow(mediaProjection)
            true
        } catch (ignored: Exception) {
            // SecurityException (no consent yet, type permission missing) or
            // ForegroundServiceStartNotAllowedException: no share then.
            false
        }
        RoomCallBridge.started(ok)
        if (!ok) {
            stopSelf()
            return START_NOT_STICKY
        }
        // Never restarted by the system: a killed process ends the share.
        return START_NOT_STICKY
    }

    @Suppress("DEPRECATION")
    private fun startForegroundNow(mediaProjection: Boolean) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(
                RoomCallRules.CHANNEL_ID, "Calls", NotificationManager.IMPORTANCE_LOW))
            Notification.Builder(this, RoomCallRules.CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        builder.setSmallIcon(applicationInfo.icon)
            .setContentTitle(RoomCallRules.NOTIFICATION_TITLE)
            .setContentText(RoomCallRules.NOTIFICATION_TEXT)
            .setOngoing(true)
        packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
            builder.setContentIntent(PendingIntent.getActivity(
                this, 0, launch,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        }
        val type = RoomCallRules.serviceType(mediaProjection, Build.VERSION.SDK_INT)
        if (type != 0 && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(RoomCallRules.NOTIFICATION_ID, builder.build(), type)
        } else {
            startForeground(RoomCallRules.NOTIFICATION_ID, builder.build())
        }
    }

    override fun onDestroy() {
        RoomCallBridge.stopped()
        super.onDestroy()
    }

    companion object {
        const val EXTRA_MEDIA_PROJECTION = "media_projection"
    }
}

/**
 * The `room_call_service` channel. All calls arrive and are answered on the
 * main thread, as are the service's callbacks, so no locking is needed.
 * Answers are `true` only when the service is running; anything else is a
 * refusal and the Dart side does not capture.
 */
object RoomCallBridge {
    const val CHANNEL = "org.veritra.private_messenger/room_call_service"

    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var timeout: Runnable? = null
    @Volatile private var running = false

    fun install(app: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> start(app, call.argument<Boolean>("mediaProjection") == true, result)
                "stop" -> {
                    stop(app)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun start(app: Context, mediaProjection: Boolean, result: MethodChannel.Result) {
        when (RoomCallRules.decide(BuildConfig.VERITRA_ROOM_SERVICE, mediaProjection, Build.VERSION.SDK_INT)) {
            RoomCallRules.Start.ALLOWED -> {}
            else -> {
                result.success(false)
                return
            }
        }
        if (pending != null) {
            result.error("busy", null, null)
            return
        }
        if (running) {
            result.success(true)
            return
        }
        pending = result
        val intent = Intent(app, RoomCallService::class.java)
            .putExtra(RoomCallService.EXTRA_MEDIA_PROJECTION, mediaProjection)
        try {
            if (Build.VERSION.SDK_INT >= 26) app.startForegroundService(intent)
            else app.startService(intent)
        } catch (ignored: Exception) {
            // ForegroundServiceStartNotAllowedException, SecurityException:
            // the app is not in a state that may start it.
            started(false)
            return
        }
        // The OS wants startForeground within five seconds; so do we.
        val deadline = Runnable {
            if (pending != null) {
                app.stopService(Intent(app, RoomCallService::class.java))
                started(false)
            }
        }
        timeout = deadline
        main.postDelayed(deadline, RoomCallRules.START_TIMEOUT_MS)
    }

    private fun stop(app: Context) {
        timeout?.let { main.removeCallbacks(it) }
        timeout = null
        pending?.success(false)
        pending = null
        app.stopService(Intent(app, RoomCallService::class.java))
        running = false
    }

    /** From the service, on the main thread, once startForeground ran or failed. */
    internal fun started(ok: Boolean) {
        timeout?.let { main.removeCallbacks(it) }
        timeout = null
        running = ok
        pending?.success(ok)
        pending = null
    }

    internal fun stopped() {
        running = false
    }
}
