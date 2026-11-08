package org.veritra.private_messenger

import org.json.JSONObject
import org.unifiedpush.android.connector.FailedReason
import org.unifiedpush.android.connector.PushService
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage

class VeritraPushService : PushService() {
    override fun onNewEndpoint(endpoint: PushEndpoint, instance: String) {
        val keys = endpoint.pubKeySet ?: return
        PushEventBridge.recordEndpoint(applicationContext, "webpush", instance,
            endpoint.url, keys.pubKey, keys.auth, temporary = endpoint.temporary)
    }

    override fun onMessage(message: PushMessage, instance: String) {
        if (!message.decrypted) return
        val payload = runCatching { JSONObject(String(message.content, Charsets.UTF_8)) }.getOrNull() ?: return
        val fields = payload.keys().asSequence().associateWith { payload.get(it) }
        when (WakeRules.payload(fields)) {
            WakeRules.Payload.LEGACY -> PushEventBridge.markWake(applicationContext)
            WakeRules.Payload.SILENT -> PushEventBridge.markWake(applicationContext, silent = true)
            else -> return
        }
    }

    override fun onUnregistered(instance: String) {
        PushEndpointStore.clearIfInstance(applicationContext, instance)
        PushEventBridge.emit(mapOf("type" to "unregistered", "instance" to instance))
    }

    override fun onRegistrationFailed(reason: FailedReason, instance: String) {
        PushEventBridge.emit(mapOf("type" to "registration_failed", "instance" to instance))
    }

}
