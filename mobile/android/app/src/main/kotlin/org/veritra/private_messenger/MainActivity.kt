package org.veritra.private_messenger

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.unifiedpush.android.connector.UnifiedPush

class MainActivity : FlutterActivity() {
    private var instance: String?
        get() = PushRegistrationConfig.instance
        set(value) { PushRegistrationConfig.instance = value }
    private var vapid: String?
        get() = PushRegistrationConfig.vapid
        set(value) { PushRegistrationConfig.vapid = value }
    private var offeredProviders: List<String>
        get() = PushRegistrationConfig.providers
        set(value) { PushRegistrationConfig.providers = value }
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingFolderResult: MethodChannel.Result? = null

    /** K1 second copy: the user picks the folder; the grant is kept. */
    internal fun pickK1Folder(result: MethodChannel.Result) {
        if (pendingFolderResult != null) {
            result.error("busy", null, null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
            K1SecondCopy.GRANT or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        pendingFolderResult = result
        try {
            startActivityForResult(intent, K1SecondCopy.PICK_REQUEST)
        } catch (_: ActivityNotFoundException) {
            pendingFolderResult = null
            result.error("no_picker", null, null)
        }
    }

    @Deprecated("FlutterActivity is not a ComponentActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != K1SecondCopy.PICK_REQUEST) return
        val result = pendingFolderResult ?: return
        pendingFolderResult = null
        val tree = data?.data
        if (resultCode != RESULT_OK || tree == null) {
            result.success(null) // Cancelled: nothing changes.
            return
        }
        try {
            contentResolver.takePersistableUriPermission(tree, K1SecondCopy.GRANT)
            result.success(mapOf(
                "tree" to tree.toString(),
                "label" to K1SecondCopy.label(applicationContext, tree)))
        } catch (_: SecurityException) {
            result.error("permission_refused", null, null)
        }
    }

    override fun onResume() {
        super.onResume()
        PushEventBridge.foreground = true
        WakeWorkerCoordinator.uiAttached(true)
    }

    override fun onPause() {
        PushEventBridge.foreground = false
        WakeWorkerCoordinator.uiAttached(false)
        super.onPause()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) return
        pendingPermissionResult?.success(notificationPermissionState())
        pendingPermissionResult = null
    }

    // "granted", "denied" or "not_determined"; Android 13+ asks at runtime.
    private fun notificationPermissionState(): String {
        if (Build.VERSION.SDK_INT >= 33) {
            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED) return "granted"
            val asked = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getBoolean(PERMISSION_ASKED, false)
            return if (asked) "denied" else "not_determined"
        }
        if (Build.VERSION.SDK_INT < 24) return "granted"
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        return if (manager?.areNotificationsEnabled() != false) "granted" else "denied"
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine = SharedFlutterEngine.get(context)
    override fun shouldDestroyEngineWithHost(): Boolean = false
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) { SharedFlutterEngine.attach(this) }
    override fun onDestroy() {
        pendingPermissionResult?.error("ui_unavailable", null, null)
        pendingPermissionResult = null
        pendingFolderResult?.error("ui_unavailable", null, null)
        pendingFolderResult = null
        SharedFlutterEngine.detach(this)
        super.onDestroy()
    }

    internal fun handlePushMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "register" -> {
                val nextInstance = call.argument<String>("instance")
                // FCM needs no VAPID key; UnifiedPush (Web Push) may use it (I41).
                val nextVapid = call.argument<String>("vapid")?.takeIf { it.isNotBlank() }
                val providers = call.argument<List<String>>("providers") ?: emptyList()
                if (nextInstance.isNullOrBlank()) {
                    result.error("invalid_arguments", "Push instance is required", null)
                } else {
                    // A new registration supersedes every callback still
                    // pending from an earlier one (TASK-013).
                    val attempt = PushRegistrationConfig.configure(nextInstance, nextVapid, providers)
                    val usingFcm = FcmBridge.isAvailable() && "fcm" in providers && FcmBridge.register(applicationContext, nextInstance, attempt) {
                        if ("unifiedpush" in offeredProviders || ("webpush" in offeredProviders && vapid != null)) {
                            registerWithDistributor(usePicker = false, attempt = attempt)
                        }
                    }
                    if (!usingFcm) {
                        if ("unifiedpush" in providers || ("webpush" in providers && nextVapid != null)) {
                            registerWithDistributor(usePicker = false, attempt = attempt)
                        } else {
                            PushEventBridge.emit(mapOf(
                                "type" to "registration_failed",
                                "instance" to nextInstance,
                                "provider" to "none"))
                        }
                    }
                    result.success(null)
                }
            }
            "notificationPermission" -> result.success(notificationPermissionState())
            "requestNotificationPermission" -> {
                if (Build.VERSION.SDK_INT >= 33 &&
                    notificationPermissionState() == "not_determined" &&
                    pendingPermissionResult == null) {
                    getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                        .edit().putBoolean(PERMISSION_ASKED, true).apply()
                    pendingPermissionResult = result
                    requestPermissions(
                        arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                        NOTIFICATION_PERMISSION_REQUEST)
                } else {
                    result.success(notificationPermissionState())
                }
            }
            "pickDistributor" -> {
                if (instance == null || ("webpush" !in offeredProviders && "unifiedpush" !in offeredProviders)) {
                    result.error("not_configured", "Push must be configured first", null)
                } else {
                    registerWithDistributor(usePicker = true, attempt = PushRegistrationConfig.generation)
                    result.success(null)
                }
            }
            // "unregister", "pendingEndpoint" and "acknowledgeEndpoint" are
            // answered by SharedFlutterEngine's channel handler (they need no
            // Activity), which never forwards them here.
            "pendingWakeGeneration" ->
                result.success(PushEventBridge.pendingWakeGeneration(applicationContext))
            "acknowledgeWake" -> {
                val generation = call.argument<Number>("generation")?.toLong()
                if (generation == null || generation <= 0) {
                    result.error("invalid_arguments", "Wake generation is required", null)
                } else {
                    result.success(PushEventBridge.acknowledgeWake(applicationContext, generation))
                }
            }
            else -> result.notImplemented()
        }
    }

    internal fun handleScreenGuardMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setSecure" -> {
                val secure = call.argument<Boolean>("secure")
                if (secure == null) {
                    result.error("invalid_arguments", "Secure flag is required", null)
                    return
                }
                if (secure) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                }
                result.success(null)
            }
            "isSecure" -> {
                val isSec = ScreenRules.isSecure(window.attributes.flags)
                result.success(isSec)
            }
            else -> result.notImplemented()
        }
    }

    private fun registerWithDistributor(usePicker: Boolean, attempt: Long) {
        if (!PushRegistrationConfig.current(attempt)) return
        val targetInstance = instance ?: return
        // The connector accepts null for no VAPID; an empty string is invalid.
        val targetVapid = vapid
        val targetProvider = if ("unifiedpush" in offeredProviders) "unifiedpush" else "webpush"
        // Distributor callbacks may arrive after this process has died.
        // Persist the selection before calling the distributor, keyed by instance.
        if (!applicationContext.getSharedPreferences("veritra_push_state", Context.MODE_PRIVATE)
                .edit().putString("distributor_instance", targetInstance)
                .putString("distributor_provider", targetProvider).commit()) {
            PushEventBridge.emit(mapOf("type" to "registration_failed",
                "instance" to targetInstance, "provider" to targetProvider))
            return
        }
        val callback: (Boolean) -> Unit = { success ->
            // Unregister or a newer register may have run while the
            // distributor picker was open; then this answer is stale.
            when {
                !PushRegistrationConfig.current(attempt) -> {}
                success -> UnifiedPush.register(applicationContext, targetInstance, "Veritra", targetVapid)
                else -> PushEventBridge.emit(mapOf(
                    "type" to "registration_failed",
                    "instance" to targetInstance,
                    "provider" to targetProvider))
            }
        }
        if (usePicker) {
            UnifiedPush.tryPickDistributor(this, callback)
        } else {
            UnifiedPush.tryUseCurrentOrDefaultDistributor(this, callback)
        }
    }

    companion object {
        private const val PUSH_METHODS = "org.veritra.private_messenger/push_methods"
        private const val PUSH_EVENTS = "org.veritra.private_messenger/push_events"
        private const val PREFS = "veritra_push_state"
        private const val PERMISSION_ASKED = "notification_permission_asked"
        private const val NOTIFICATION_PERMISSION_REQUEST = 4101
    }
}

// The one notification Veritra shows (I41): a fixed sentence, never message
// text, a sender or a conversation. Shown only while the app is not in the
// foreground and only when notifications are allowed.
object GenericNotification {
    private const val CHANNEL = "veritra_messages"
    private const val ID = 4102

    @Suppress("DEPRECATION")
    fun show(context: Context, notificationId: Int = ID): Boolean {
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED) return false
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return false
        if (Build.VERSION.SDK_INT >= 24 && !manager.areNotificationsEnabled()) return false
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(
                CHANNEL, "Messages", NotificationManager.IMPORTANCE_DEFAULT))
            Notification.Builder(context, CHANNEL)
        } else {
            Notification.Builder(context)
        }
        builder.setSmallIcon(context.applicationInfo.icon)
            .setContentTitle("Veritra")
            .setContentText("New encrypted message")
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
        context.packageManager.getLaunchIntentForPackage(context.packageName)?.let { launch ->
            builder.setContentIntent(PendingIntent.getActivity(
                context, 0, launch,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        }
        if (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(CHANNEL)?.importance == NotificationManager.IMPORTANCE_NONE) return false
        manager.notify(notificationId, builder.build())
        return true
    }
}

object PushEventBridge : EventChannel.StreamHandler {
    @Volatile var foreground: Boolean = false
    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    @Volatile private var sink: EventChannel.EventSink? = null
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
    override fun onCancel(arguments: Any?) { sink = null }
    fun emit(event: Map<String, Any?>) { main.post { sink?.success(event) } }
    fun markWake(context: Context, silent: Boolean = false) {
        if (WakeMarkerStore.mark(context) <= 0) return
        emit(mapOf("type" to "wake"))
        if (silent) WakeWorkerCoordinator.schedule(context)
        else main.post { if (!foreground) GenericNotification.show(context) }
    }
    fun pendingWakeGeneration(context: Context): Long = WakeMarkerStore.pending(context)
    fun acknowledgeWake(context: Context, generation: Long): Boolean = WakeMarkerStore.acknowledge(context, generation)
    fun clearPendingWake(context: Context) { WakeMarkerStore.clear(context) }

    /** Stores the rotation durably, then emits it live. Listener attach never
     * clears the record; only [acknowledgeEndpoint] does. */
    @Synchronized fun recordEndpoint(
        context: Context, provider: String, instance: String,
        endpoint: String, publicKey: String, authSecret: String,
        temporary: Boolean? = null,
    ) {
        val generation = PushEndpointStore.record(context, provider, instance, endpoint, publicKey, authSecret)
        val event = mutableMapOf<String, Any?>(
            "type" to "endpoint", "provider" to provider, "instance" to instance,
            "endpoint" to endpoint, "publicKey" to publicKey, "authSecret" to authSecret,
            "generation" to generation)
        if (temporary != null) event["temporary"] = temporary
        emit(event)
    }
    fun pendingEndpoint(context: Context): Map<String, Any?>? = PushEndpointStore.pending(context)
    fun acknowledgeEndpoint(context: Context, generation: Long): Boolean = PushEndpointStore.acknowledge(context, generation)
}

/** Main-thread confined. [generation] changes on every register and
 * unregister; an async callback acts only if the generation it captured is
 * still current, so unregister leaves a stable unregistered state. */
object PushRegistrationConfig {
    var instance: String? = null
    var vapid: String? = null
    var providers: List<String> = emptyList()
    @Volatile var generation: Long = 0
        private set

    fun current(attempt: Long): Boolean = attempt == generation

    fun configure(nextInstance: String, nextVapid: String?, nextProviders: List<String>): Long {
        instance = nextInstance
        vapid = nextVapid
        providers = nextProviders
        return ++generation
    }

    fun clear(context: Context) {
        generation++
        instance = null
        vapid = null
        providers = emptyList()
        // Without a bound instance, a later FCM token refresh is not forwarded.
        context.getSharedPreferences("veritra_push_state", Context.MODE_PRIVATE)
            .edit().remove("fcm_instance").remove("distributor_instance")
            .remove("distributor_provider").commit()
    }
}
