package org.veritra.private_messenger

import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.unifiedpush.android.connector.FailedReason
import org.unifiedpush.android.connector.PushService
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage

class VeritraPushService : PushService() {
    private var backgroundEngine: FlutterEngine? = null

    override fun onNewEndpoint(endpoint: PushEndpoint, instance: String) {
        val keys = endpoint.pubKeySet ?: return
        PushEventBridge.emit(mapOf(
            "type" to "endpoint",
            "instance" to instance,
            "endpoint" to endpoint.url,
            "publicKey" to keys.pubKey,
            "authSecret" to keys.auth,
            "temporary" to endpoint.temporary,
        ))
    }

    override fun onMessage(message: PushMessage, instance: String) {
        if (!message.decrypted) return
        val payload = runCatching { JSONObject(String(message.content, Charsets.UTF_8)) }.getOrNull() ?: return
        if (payload.optString("version") != "v1" ||
            payload.optString("event") != "new_encrypted_event_available") return
        PushEventBridge.markWake(applicationContext)
        if (!PushEventBridge.hasListener()) startBackgroundCatchUp()
    }

    override fun onUnregistered(instance: String) {
        PushEventBridge.emit(mapOf("type" to "unregistered", "instance" to instance))
    }

    override fun onRegistrationFailed(reason: FailedReason, instance: String) {
        PushEventBridge.emit(mapOf("type" to "registration_failed", "instance" to instance))
    }

    private fun startBackgroundCatchUp() {
        if (backgroundEngine != null) return
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationComplete(applicationContext, null)
        val engine = FlutterEngine(applicationContext)
        backgroundEngine = engine
        MethodChannel(
            engine.dartExecutor.binaryMessenger,
            BACKGROUND_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method == "complete") {
                if (call.argument<Boolean>("succeeded") == true) {
                    PushEventBridge.clearPendingWake(applicationContext)
                }
                result.success(null)
                engine.destroy()
                backgroundEngine = null
                stopSelf()
            } else {
                result.notImplemented()
            }
        }
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "pushBackgroundMain"),
        )
    }

    companion object {
        private const val BACKGROUND_CHANNEL =
            "org.veritra.private_messenger/push_background"
    }
}
