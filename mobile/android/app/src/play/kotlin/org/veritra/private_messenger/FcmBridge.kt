package org.veritra.private_messenger

import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging

object FcmBridge {
    fun isAvailable(): Boolean = true

    fun register(context: Context, instance: String, attempt: Long, onFallback: () -> Unit): Boolean {
        if (BuildConfig.VERITRA_FCM_APPLICATION_ID.isBlank() ||
            BuildConfig.VERITRA_FCM_API_KEY.isBlank() ||
            BuildConfig.VERITRA_FCM_PROJECT_ID.isBlank() ||
            BuildConfig.VERITRA_FCM_SENDER_ID.isBlank()) return false
        if (FirebaseApp.getApps(context).isEmpty()) {
            FirebaseApp.initializeApp(context, FirebaseOptions.Builder()
                .setApplicationId(BuildConfig.VERITRA_FCM_APPLICATION_ID)
                .setApiKey(BuildConfig.VERITRA_FCM_API_KEY)
                .setProjectId(BuildConfig.VERITRA_FCM_PROJECT_ID)
                .setGcmSenderId(BuildConfig.VERITRA_FCM_SENDER_ID)
                .build())
        }
        context.getSharedPreferences("veritra_push_state", Context.MODE_PRIVATE)
            .edit().putString("fcm_instance", instance).apply()
        FirebaseMessaging.getInstance().token
            .addOnSuccessListener { token ->
                if (!PushRegistrationConfig.current(attempt)) return@addOnSuccessListener
                PushEventBridge.recordEndpoint(context, "fcm", instance, token, "", "")
            }
            .addOnFailureListener {
                if (!PushRegistrationConfig.current(attempt)) return@addOnFailureListener
                PushEventBridge.emit(mapOf(
                    "type" to "registration_failed",
                    "instance" to instance,
                    "provider" to "fcm"))
                onFallback()
            }
        return true
    }

    fun deleteToken(context: Context) {
        if (FirebaseApp.getApps(context).isNotEmpty()) {
            FirebaseMessaging.getInstance().deleteToken()
        }
    }
}
