package org.veritra.private_messenger

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class VeritraFirebaseMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        if (message.data["version"] == "v1" &&
            message.data["event"] == "new_encrypted_event_available") {
            PushEventBridge.markWake(applicationContext)
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
