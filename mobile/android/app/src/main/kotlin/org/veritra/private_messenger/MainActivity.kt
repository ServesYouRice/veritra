package org.veritra.private_messenger

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
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
                        registerWithDistributor(usePicker = false)
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
