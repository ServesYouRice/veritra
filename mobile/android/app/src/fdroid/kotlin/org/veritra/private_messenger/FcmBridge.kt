package org.veritra.private_messenger

import android.content.Context

object FcmBridge {
    fun isAvailable(): Boolean = false

    fun register(context: Context, instance: String, attempt: Long, onFallback: () -> Unit): Boolean {
        return false
    }

    fun deleteToken(context: Context) {
        // No FCM in F-Droid flavor.
    }
}
