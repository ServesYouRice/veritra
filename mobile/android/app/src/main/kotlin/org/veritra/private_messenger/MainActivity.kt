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
                    result.success(null)
                }
                "takeWake" -> result.success(PushEventBridge.takePendingWake(applicationContext))
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
    private const val PENDING_WAKE = "pending_wake"
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

    fun markWake(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(PENDING_WAKE, true).apply()
        emit(mapOf("type" to "wake"))
    }

    fun hasListener(): Boolean = sink != null

    fun clearPendingWake(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().remove(PENDING_WAKE).apply()
    }

    fun takePendingWake(context: Context): Boolean {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val pending = preferences.getBoolean(PENDING_WAKE, false)
        if (pending) preferences.edit().remove(PENDING_WAKE).apply()
        return pending
    }
}
