package org.veritra.private_messenger

import android.content.Context

/** Newest push endpoint (FCM token or UnifiedPush endpoint) not yet
 * acknowledged by the app. Private storage, excluded from backup. A newer
 * rotation overwrites the record and bumps the generation; an older
 * acknowledgement never clears it. The values are never logged. */
object PushEndpointStore {
    private const val PREFS = "veritra_push_state"
    private const val PENDING = "endpoint_generation"
    private const val SEQUENCE = "endpoint_sequence"
    private val FIELDS = listOf("endpoint_provider", "endpoint_instance", "endpoint_url",
        "endpoint_public_key", "endpoint_auth_secret")

    /** Returns the new generation, or 0 when the record could not be stored. */
    @Synchronized fun record(
        context: Context, provider: String, instance: String,
        endpoint: String, publicKey: String, authSecret: String,
    ): Long = runCatching {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val next = EndpointRules.nextGeneration(prefs.getLong(SEQUENCE, 0))
        val ok = prefs.edit()
            .putLong(SEQUENCE, next).putLong(PENDING, next)
            .putString("endpoint_provider", provider).putString("endpoint_instance", instance)
            .putString("endpoint_url", endpoint).putString("endpoint_public_key", publicKey)
            .putString("endpoint_auth_secret", authSecret).commit()
        if (ok) next else 0
    }.getOrDefault(0)

    /** The stored record as a method-channel map, or null when none/corrupt. */
    @Synchronized fun pending(context: Context): Map<String, Any?>? = runCatching {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val generation = prefs.getLong(PENDING, 0)
        if (generation <= 0) return@runCatching null
        mapOf(
            "generation" to generation,
            "provider" to prefs.getString("endpoint_provider", null)!!,
            "instance" to prefs.getString("endpoint_instance", null)!!,
            "endpoint" to prefs.getString("endpoint_url", null)!!,
            "publicKey" to prefs.getString("endpoint_public_key", null)!!,
            "authSecret" to prefs.getString("endpoint_auth_secret", null)!!,
        )
    }.getOrNull()

    /** True only if [generation] is still the stored one and was cleared. A
     * failed write puts the whole record back (SharedPreferences changes its
     * in-memory copy even when commit fails). */
    @Synchronized fun acknowledge(context: Context, generation: Long): Boolean = runCatching {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (generation <= 0 || prefs.getLong(PENDING, 0) != generation) return@runCatching false
        val saved = FIELDS.associateWith { prefs.getString(it, null) }
        val edit = prefs.edit().remove(PENDING)
        FIELDS.forEach { edit.remove(it) }
        if (edit.commit()) return@runCatching true
        val restore = prefs.edit().putLong(PENDING, generation)
        saved.forEach { (key, value) -> if (value != null) restore.putString(key, value) }
        restore.commit()
        false
    }.getOrDefault(false)

    /** Drops the record when its instance was unregistered by the platform. */
    @Synchronized fun clearIfInstance(context: Context, instance: String): Boolean {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return if (prefs.getString("endpoint_instance", null) == instance) clear(context) else false
    }

    @Synchronized fun clear(context: Context): Boolean {
        val edit = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(PENDING)
        FIELDS.forEach { edit.remove(it) }
        return edit.commit()
    }
}
