package org.veritra.private_messenger

import org.json.JSONObject
import org.unifiedpush.android.connector.FailedReason
import org.unifiedpush.android.connector.PushService
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage

class VeritraPushService : PushService() {
    private fun providerFor(instance: String): String {
        val prefs = applicationContext.getSharedPreferences("veritra_push_state", android.content.Context.MODE_PRIVATE)
        return EndpointRules.distributorProvider(instance,
            prefs.getString("distributor_instance", null),
            prefs.getString("distributor_provider", null))
    }

    override fun onNewEndpoint(endpoint: PushEndpoint, instance: String) {
        val keys = endpoint.pubKeySet
        val pubKey = keys?.pubKey ?: ""
        val auth = keys?.auth ?: ""
        val provider = providerFor(instance)
        PushEventBridge.recordEndpoint(applicationContext, provider, instance,
            endpoint.url, pubKey, auth, temporary = endpoint.temporary)
    }

    override fun onMessage(message: PushMessage, instance: String) {
        val content = String(message.content, Charsets.UTF_8)
        val payload = runCatching { JSONObject(content) }.getOrNull() ?: return
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
        val provider = providerFor(instance)
        PushEventBridge.emit(mapOf("type" to "registration_failed", "instance" to instance, "provider" to provider))
    }
}
