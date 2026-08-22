package org.veritra.private_messenger

import org.json.JSONObject
import org.unifiedpush.android.connector.FailedReason
import org.unifiedpush.android.connector.PushService
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage

class VeritraPushService : PushService() {
    override fun onNewEndpoint(endpoint: PushEndpoint, instance: String) {
        val keys = endpoint.pubKeySet ?: return
        PushEventBridge.emit(mapOf(
            "type" to "endpoint",
            "provider" to "webpush",
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
    }

    override fun onUnregistered(instance: String) {
        PushEventBridge.emit(mapOf("type" to "unregistered", "instance" to instance))
    }

    override fun onRegistrationFailed(reason: FailedReason, instance: String) {
        PushEventBridge.emit(mapOf("type" to "registration_failed", "instance" to instance))
    }

}
