package org.veritra.private_messenger

import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

object WakeWorkerCoordinator {
    const val COLD_EXECUTION_ENABLED = false
    private const val JOB_ID = 4103
    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var profile: String? = null
    private var launchBackground = false
    private var ui = false
    private class Active(val permit: WakeRules.Permit, val finish: (Boolean) -> Unit) {
        lateinit var timeout: Runnable
    }
    private var active: Active? = null
    private class PendingStart(val context: Context, val startedAt: Long, val finish: (Boolean) -> Unit) {
        lateinit var timeout: Runnable
    }
    private var pendingStart: PendingStart? = null
    fun installChannel(context: Context, messenger: BinaryMessenger, background: Boolean) {
        check(Looper.myLooper() == Looper.getMainLooper())
        check(channel == null)
        this.context = context.applicationContext
        launchBackground = background
        channel = MethodChannel(messenger, "org.veritra.private_messenger/wake_worker").also { ch ->
            ch.setMethodCallHandler { call, result ->
                if (call.method == "bootstrap" && call.arguments == null) {
                    val metadata = runCatching { WakeMarkerStore.bootstrapBinding(context) }
                    result.success(WakeRules.bootstrap(launchBackground, ui, metadata.getOrNull(), metadata.isSuccess))
                    return@setMethodCallHandler
                }
                val args = call.arguments as? Map<*, *>
                val name = args?.get("profile") as? String
                if (args?.get("protocol") != 1 || !WakeRules.profile(name)) {
                    result.error("invalid_wake_protocol", null, null); return@setMethodCallHandler
                }
                when (call.method) {
                    "install" -> {
                        if (args.keys != setOf("protocol", "profile") || (profile != null && profile != name)) {
                            result.error("wake_owner_conflict", null, null)
                        } else if (!context.getSharedPreferences("veritra_push_state", Context.MODE_PRIVATE)
                                .edit().putString("wake_profile", name).commit()) {
                            result.error("wake_storage_unavailable", null, null)
                        } else {
                            profile = name
                            result.success(mapOf("protocol" to 1, "native_silent" to true,
                                "worker_attached" to true, "can_opt_in" to false))
                            pendingStart?.let { pending ->
                                pendingStart = null
                                main.removeCallbacks(pending.timeout)
                                run(pending.context, pending.startedAt, pending.finish)
                            }
                        }
                    }
                    "uninstall" -> {
                        if (args.keys != setOf("protocol", "profile") || (profile != null && profile != name)) {
                            result.success(false)
                        } else { result.success(unregister(context)) }
                    }
                    "validatePermit", "presentGenericNotice" -> {
                        val allowed = if (call.method == "validatePermit") setOf("protocol", "permit", "profile")
                            else setOf("protocol", "permit", "profile", "notice_id")
                        val id = args["permit"] as? String
                        val permit = active?.permit
                        val valid = args.keys == allowed && id != null && profile == name &&
                            permit?.matches(id, name, SystemClock.elapsedRealtime()) == true
                        if (call.method == "validatePermit") {
                            val remaining = if (valid) permit.remaining(SystemClock.elapsedRealtime()) else 0L
                            result.success(mapOf("active" to (remaining > 0), "remaining_ms" to remaining))
                        } else {
                            val notice = args["notice_id"] as? String
                            if (!valid || notice == null || !notice.matches(Regex("[0-9a-f]{32}"))) result.success("unavailable")
                            else if (PushEventBridge.foreground) result.success("suppressed")
                            else when (WakeMarkerStore.claimNotice(context, name!!, notice)) {
                                2 -> result.success("suppressed")
                                1 -> {
                                    if (!permit.matches(id, name, SystemClock.elapsedRealtime())) result.success("unavailable")
                                    else result.success(if (GenericNotification.show(context, notice.take(8).toLong(16).toInt())) "shown" else "suppressed")
                                }
                                else -> result.success("unavailable")
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }
    fun uiAttached(attached: Boolean) {
        check(Looper.myLooper() == Looper.getMainLooper())
        ui = attached
        if (attached && (active != null || pendingStart != null)) cancel("os_stop")
        channel?.invokeMethod("uiAttached", mapOf("protocol" to 1, "attached" to attached))
    }
    fun schedule(context: Context) {
        main.post {
            if (active != null || pendingStart != null) return@post
            val scheduler = context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as? JobScheduler ?: return@post
            val info = JobInfo.Builder(JOB_ID, ComponentName(context, VeritraWakeJobService::class.java))
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                .setBackoffCriteria(30000, JobInfo.BACKOFF_POLICY_EXPONENTIAL).build()
            scheduler.schedule(info)
        }
    }
    fun run(context: Context, startedAt: Long, finish: (Boolean) -> Unit) {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (active != null || pendingStart != null) { finish(true); return }
        val generation = WakeMarkerStore.pending(context)
        if (generation <= 0) { finish(false); return }
        if (PushEventBridge.foreground) { finish(false); return }
        if (SharedFlutterEngine.existing() == null) {
            if (!COLD_EXECUTION_ENABLED) { finish(true); return }
            SharedFlutterEngine.get(context, background = true)
        }
        val name = profile
        val ch = channel
        val budget = 20000 - (SystemClock.elapsedRealtime() - startedAt)
        if (budget <= 0) { finish(true); return }
        if (name == null || ch == null) {
            val pending = PendingStart(context, startedAt, finish)
            pendingStart = pending
            pending.timeout = Runnable {
                if (pendingStart === pending) { pendingStart = null; pending.finish(true) }
            }
            main.postDelayed(pending.timeout, budget)
            return
        }
        val entry = Active(WakeRules.Permit(name, generation, SystemClock.elapsedRealtime(), budget), finish)
        active = entry
        entry.timeout = Runnable { if (active === entry) cancel("deadline") }
        main.postDelayed(entry.timeout, budget)
        ch.invokeMethod("run", mapOf("protocol" to 1, "permit" to entry.permit.id,
            "profile" to name, "wake_generation" to generation, "budget_ms" to budget,
            "deadline_epoch_ms" to System.currentTimeMillis() + budget), object : MethodChannel.Result {
            override fun success(result: Any?) {
                if (active !== entry) return
                val durable = result is Map<*, *> && entry.permit.durableOutcome(result, SystemClock.elapsedRealtime())
                val acknowledged = durable && WakeMarkerStore.acknowledge(context, generation)
                complete(entry, !acknowledged || WakeMarkerStore.pending(context) > 0)
            }
            override fun error(code: String, message: String?, details: Any?) { if (active === entry) complete(entry, true) }
            override fun notImplemented() { if (active === entry) complete(entry, true) }
        })
    }
    private fun complete(entry: Active, retry: Boolean, notify: Boolean = true) {
        if (active !== entry) return
        entry.permit.revoke()
        active = null
        main.removeCallbacks(entry.timeout)
        if (notify) entry.finish(retry)
    }
    fun cancel(reason: String, notify: Boolean = true) {
        pendingStart?.let {
            pendingStart = null
            main.removeCallbacks(it.timeout)
            if (notify) it.finish(true)
        }
        val entry = active ?: return
        entry.permit.revoke()
        channel?.invokeMethod("cancel", mapOf("protocol" to 1, "permit" to entry.permit.id,
            "profile" to entry.permit.profile, "reason" to reason))
        complete(entry, true, notify)
    }
    fun unregister(context: Context): Boolean {
        cancel("unregistered")
        profile = null
        (context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as? JobScheduler)?.cancel(JOB_ID)
        val cleared = WakeMarkerStore.clear(context)
        val unbound = context.getSharedPreferences("veritra_push_state", Context.MODE_PRIVATE).edit().remove("wake_profile").commit()
        return cleared && unbound
    }
}
