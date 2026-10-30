package org.veritra.private_messenger

import android.content.Context
import org.json.JSONObject

/** Sequence survives ACK and logout; stale ACKs cannot clear a later wake. */
object WakeMarkerStore {
    private const val PREFS = "veritra_push_state"
    private const val PENDING = "pending_wake_generation"
    private const val SEQUENCE = "wake_sequence"
    private const val LEGACY = "pending_wake"
    /** Read-only bootstrap probe. Corrupt notification metadata is not a reason
     * to deny an actual UI launch or create/repair a protected database. */
    @Synchronized fun bootstrapBinding(context: Context): String? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        check(prefs.getLong(SEQUENCE, 0) >= 0 && prefs.getLong(PENDING, 0) >= 0)
        prefs.getBoolean(LEGACY, false)
        val bound = prefs.getString("wake_profile", null)
        check(bound == null || WakeRules.profile(bound))
        val clock = prefs.getLong("wake_notice_clock", 0)
        check(clock >= 0)
        val raw = prefs.getString("wake_notice_journal", "{}") ?: error("invalid wake journal")
        check(raw.length <= 512 * 1024)
        val notices = JSONObject(raw)
        check(notices.length() <= WakeRules.MAX_NOTICE_ENTRIES)
        for (key in notices.keys()) {
            check(key.matches(Regex("[a-z][a-z0-9-]{0,39}:[0-9a-f]{32}")))
            val value = notices.get(key)
            check(value is Long || value is Int)
            check((value as Number).toLong() in 0..clock)
        }
        return bound
    }
    @Synchronized fun pending(context: Context): Long = runCatching { pendingRaw(context) }.getOrDefault(0)
    private fun pendingRaw(context: Context): Long {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val pending = prefs.getLong(PENDING, 0)
        val sequence = prefs.getLong(SEQUENCE, 0)
        check(pending >= 0 && sequence >= 0) { "invalid wake journal" }
        if (pending > 0) return pending
        if (!prefs.getBoolean(LEGACY, false)) return 0
        val next = runCatching { WakeRules.nextGeneration(sequence, 0) }.getOrNull() ?: return 0
        return if (prefs.edit().putLong(SEQUENCE, next).putLong(PENDING, next).remove(LEGACY).commit()) next else 0
    }
    @Synchronized fun mark(context: Context): Long = runCatching {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val old = pendingRaw(context)
        val next = runCatching { WakeRules.nextGeneration(prefs.getLong(SEQUENCE, 0), old) }.getOrNull() ?: return 0
        if (prefs.edit().putLong(SEQUENCE, next).putLong(PENDING, next).remove(LEGACY).commit()) next else 0
    }.getOrDefault(0)
    @Synchronized fun acknowledge(context: Context, generation: Long): Boolean = runCatching {
        WakeRules.acknowledge(object : WakeRules.PendingStore {
            override fun pending(): Long = pendingRaw(context)
            override fun writePending(value: Long): Boolean {
                val edit = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(LEGACY)
                if (value == 0L) edit.remove(PENDING) else edit.putLong(PENDING, value)
                return edit.commit()
            }
        }, generation)
    }.getOrDefault(false)
    @Synchronized fun clear(context: Context): Boolean = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        .edit().remove(PENDING).remove(LEGACY).commit()

    // 1=new durable attempt; 2=already consumed; 0=unavailable. No fresh ID is
    // evicted to make room. Failed persistence never permits an OS alert.
    @Synchronized fun claimNotice(context: Context, profile: String, id: String): Int = runCatching {
        if (!WakeRules.profile(profile) || !id.matches(Regex("[0-9a-f]{32}"))) return 0
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val raw = prefs.getString("wake_notice_journal", "{}") ?: return 0
        if (raw.length > 512 * 1024) return 0
        val json = JSONObject(raw)
        if (json.length() > WakeRules.MAX_NOTICE_ENTRIES) return 0
        val records = mutableMapOf<String, Long>()
        for (key in json.keys()) {
            if (!key.matches(Regex("[a-z][a-z0-9-]{0,39}:[0-9a-f]{32}"))) return 0
            val value = json.get(key)
            if (value !is Long && value !is Int) return 0
            records[key] = (value as Number).toLong()
        }
        val clock = prefs.getLong("wake_notice_clock", 0)
        val now = System.currentTimeMillis()
        when (WakeRules.claimNotice(records, clock, now, "$profile:$id")) {
            WakeRules.NoticeClaim.CLOCK_ROLLBACK, WakeRules.NoticeClaim.FULL -> 0
            else -> {
                val existed = json.has("$profile:$id") && now - json.getLong("$profile:$id") <= WakeRules.NOTICE_RETENTION_MS
                val updated = JSONObject()
                for ((key, time) in records) updated.put(key, time)
                if (!prefs.edit().putString("wake_notice_journal", updated.toString()).putLong("wake_notice_clock", now).commit()) 0
                else if (existed) 2 else 1
            }
        }
    }.getOrDefault(0)
}
