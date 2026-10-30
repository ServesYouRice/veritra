package org.veritra.private_messenger

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class VeritraFirebaseMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        when (WakeRules.payload(message.data)) {
            WakeRules.Payload.LEGACY -> PushEventBridge.markWake(applicationContext)
            WakeRules.Payload.SILENT -> PushEventBridge.markWake(applicationContext, silent = true)
            else -> return
        }
    }

    override fun onNewToken(token: String) {
        val instance = getSharedPreferences("veritra_push_state", MODE_PRIVATE)
            .getString("fcm_instance", null) ?: return
        PushEventBridge.emit(mapOf(
            "type" to "endpoint",
            "provider" to "fcm",
            "instance" to instance,
            "endpoint" to token,
            "publicKey" to "",
            "authSecret" to "",
        ))
    }
}
