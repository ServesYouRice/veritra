package org.veritra.private_messenger

import android.content.Context
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        EventChannel(messenger, PUSH_EVENTS).setStreamHandler(PushEventBridge)
        MethodChannel(messenger, PUSH_METHODS).setMethodCallHandler { call, result ->
            when (call.method) {
                "register" -> {
                    val nextInstance = call.argument<String>("instance")
                    val nextVapid = call.argument<String>("vapid")
                    if (nextInstance.isNullOrBlank() || nextVapid.isNullOrBlank()) {
                        result.error("invalid_arguments", "Push instance and VAPID key are required", null)
                    } else {
                        instance = nextInstance
                        vapid = nextVapid
                        if (!registerWithFCM()) registerWithDistributor(usePicker = false)
                        result.success(null)
                    }
                }
                "pickDistributor" -> {
                    if (instance == null || vapid == null) {
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
            .addOnFailureListener { registerWithDistributor(usePicker = false) }
        return true
    }

    companion object {
        private const val PUSH_METHODS = "org.veritra.private_messenger/push_methods"
        private const val PUSH_EVENTS = "org.veritra.private_messenger/push_events"
    }
}

object PushEventBridge : EventChannel.StreamHandler {
    private const val PREFS = "veritra_push_state"
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
