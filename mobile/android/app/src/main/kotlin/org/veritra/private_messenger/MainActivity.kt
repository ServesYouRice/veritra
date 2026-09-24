package org.veritra.private_messenger

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import org.unifiedpush.android.connector.UnifiedPush

class MainActivity : FlutterActivity() {
    private var instance: String? = null
    private var vapid: String? = null
    private var offeredProviders: List<String> = emptyList()
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun onResume() {
        super.onResume()
        PushEventBridge.foreground = true
    }

    override fun onPause() {
        PushEventBridge.foreground = false
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        EventChannel(messenger, PUSH_EVENTS).setStreamHandler(PushEventBridge)
        MethodChannel(messenger, PUSH_METHODS).setMethodCallHandler { call, result ->
            when (call.method) {
                "register" -> {
                    val nextInstance = call.argument<String>("instance")
                    // FCM needs no VAPID key; only UnifiedPush (Web Push) does (I41).
                    val nextVapid = call.argument<String>("vapid")?.takeIf { it.isNotBlank() }
                    val providers = call.argument<List<String>>("providers") ?: emptyList()
                    if (nextInstance.isNullOrBlank()) {
                        result.error("invalid_arguments", "Push instance is required", null)
                    } else {
                        instance = nextInstance
                        vapid = nextVapid
                        offeredProviders = providers
                        val usingFcm = "fcm" in providers && registerWithFCM()
                        if (!usingFcm) {
                            if ("webpush" in providers && nextVapid != null) {
                                registerWithDistributor(usePicker = false)
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
                    if (instance == null || vapid == null || "webpush" !in offeredProviders) {
                        result.error("not_configured", "Push must be configured first", null)
                    } else {
                        registerWithDistributor(usePicker = true)
                        result.success(null)
                    }
                }
                "unregister" -> {
                    val target = call.argument<String>("instance")
                    if (!target.isNullOrBlank()) UnifiedPush.unregister(applicationContext, target)
                    if (FirebaseApp.getApps(applicationContext).isNotEmpty()) {
                        FirebaseMessaging.getInstance().deleteToken()
                    }
                    PushEventBridge.clearPendingWake(applicationContext)
                    result.success(null)
                }
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
    }

    private fun registerWithDistributor(usePicker: Boolean) {
        val targetInstance = instance ?: return
        val targetVapid = vapid ?: return
        val callback: (Boolean) -> Unit = { success ->
            if (success) {
                UnifiedPush.register(applicationContext, targetInstance, "Veritra", targetVapid)
            } else {
                PushEventBridge.emit(mapOf(
                    "type" to "registration_failed",
                    "instance" to targetInstance,
                    "provider" to "webpush"))
            }
        }
        if (usePicker) {
            UnifiedPush.tryPickDistributor(this, callback)
        } else {
            UnifiedPush.tryUseCurrentOrDefaultDistributor(this, callback)
        }
    }

    private fun registerWithFCM(): Boolean {
        val targetInstance = instance ?: return false
        if (BuildConfig.VERITRA_FCM_APPLICATION_ID.isBlank() ||
            BuildConfig.VERITRA_FCM_API_KEY.isBlank() ||
            BuildConfig.VERITRA_FCM_PROJECT_ID.isBlank() ||
            BuildConfig.VERITRA_FCM_SENDER_ID.isBlank()) return false
        if (FirebaseApp.getApps(applicationContext).isEmpty()) {
            FirebaseApp.initializeApp(applicationContext, FirebaseOptions.Builder()
                .setApplicationId(BuildConfig.VERITRA_FCM_APPLICATION_ID)
                .setApiKey(BuildConfig.VERITRA_FCM_API_KEY)
                .setProjectId(BuildConfig.VERITRA_FCM_PROJECT_ID)
                .setGcmSenderId(BuildConfig.VERITRA_FCM_SENDER_ID)
                .build())
        }
        applicationContext.getSharedPreferences("veritra_push_state", Context.MODE_PRIVATE)
            .edit().putString("fcm_instance", targetInstance).apply()
        FirebaseMessaging.getInstance().token
            .addOnSuccessListener { token -> PushEventBridge.emit(mapOf(
                "type" to "endpoint", "provider" to "fcm",
                "instance" to targetInstance, "endpoint" to token,
                "publicKey" to "", "authSecret" to "")) }
            .addOnFailureListener {
                PushEventBridge.emit(mapOf(
                    "type" to "registration_failed",
                    "instance" to targetInstance,
                    "provider" to "fcm"))
                if ("webpush" in offeredProviders && vapid != null) {
                    registerWithDistributor(usePicker = false)
                }
            }
        return true
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
    fun show(context: Context) {
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return
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
            .setAutoCancel(true)
        context.packageManager.getLaunchIntentForPackage(context.packageName)?.let { launch ->
            builder.setContentIntent(PendingIntent.getActivity(
                context, 0, launch,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        }
        manager.notify(ID, builder.build())
    }
}

object PushEventBridge : EventChannel.StreamHandler {
    private const val PREFS = "veritra_push_state"
    @Volatile var foreground: Boolean = false
    private const val LEGACY_PENDING_WAKE = "pending_wake"
    private const val PENDING_WAKE_GENERATION = "pending_wake_generation"
    @Volatile private var sink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    fun emit(event: Map<String, Any?>) {
        sink?.success(event)
    }

    @Synchronized
    fun markWake(context: Context) {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val next = migrateLegacyGeneration(preferences) + 1
        preferences.edit().putLong(PENDING_WAKE_GENERATION, next).commit()
        emit(mapOf("type" to "wake"))
        if (!foreground) GenericNotification.show(context)
    }

    @Synchronized
    fun pendingWakeGeneration(context: Context): Long {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return migrateLegacyGeneration(preferences)
    }

    @Synchronized
    fun acknowledgeWake(context: Context, generation: Long): Boolean {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val current = migrateLegacyGeneration(preferences)
        if (current != generation) return false
        preferences.edit().remove(PENDING_WAKE_GENERATION).remove(LEGACY_PENDING_WAKE).commit()
        return true
    }

    @Synchronized
    fun clearPendingWake(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().remove(PENDING_WAKE_GENERATION).remove(LEGACY_PENDING_WAKE).commit()
    }

    private fun migrateLegacyGeneration(preferences: android.content.SharedPreferences): Long {
        val current = preferences.getLong(PENDING_WAKE_GENERATION, 0L)
        if (current > 0L) return current
        if (!preferences.getBoolean(LEGACY_PENDING_WAKE, false)) return 0L
        preferences.edit().putLong(PENDING_WAKE_GENERATION, 1L)
            .remove(LEGACY_PENDING_WAKE).commit()
        return 1L
    }
}
