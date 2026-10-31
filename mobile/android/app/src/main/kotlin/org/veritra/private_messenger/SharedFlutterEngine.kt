package org.veritra.private_messenger

import android.content.Context
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import org.unifiedpush.android.connector.UnifiedPush
import java.lang.ref.WeakReference

/** Exactly one normal compiled root and plugin registry per process. */
object SharedFlutterEngine {
    private var engine: FlutterEngine? = null
    private var activity = WeakReference<MainActivity>(null)
    fun existing(): FlutterEngine? = engine
    fun attach(activity: MainActivity) { this.activity = WeakReference(activity); WakeWorkerCoordinator.uiAttached(true) }
    fun detach(activity: MainActivity) {
        if (this.activity.get() === activity) { this.activity.clear(); WakeWorkerCoordinator.uiAttached(false) }
    }
    fun get(context: Context, background: Boolean = false): FlutterEngine {
        check(Looper.myLooper() == Looper.getMainLooper())
        engine?.let { return it }
        // Cold background execution stays off until the Dart bootstrap and
        // existing-only protected-store path have passed their own review.
        check(!background || WakeWorkerCoordinator.COLD_EXECUTION_ENABLED)
        val app = context.applicationContext
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(app)
        loader.ensureInitializationComplete(app, null)
        val created = FlutterEngine(app)
        engine = created
        val messenger = created.dartExecutor.binaryMessenger
        EventChannel(messenger, "org.veritra.private_messenger/push_events").setStreamHandler(PushEventBridge)
        MethodChannel(messenger, "org.veritra.private_messenger/push_methods").setMethodCallHandler { call, result ->
            when (call.method) {
                "pendingWakeGeneration" -> result.success(WakeMarkerStore.pending(app))
                "acknowledgeWake" -> {
                    val generation = call.argument<Number>("generation")?.toLong()
                    result.success(generation != null && WakeMarkerStore.acknowledge(app, generation))
                }
                "unregister" -> {
                    WakeWorkerCoordinator.unregister(app)
                    val target = call.argument<String>("instance") ?: PushRegistrationConfig.instance
                    if (!target.isNullOrBlank()) UnifiedPush.unregister(app, target)
                    if (FirebaseApp.getApps(app).isNotEmpty()) FirebaseMessaging.getInstance().deleteToken()
                    PushRegistrationConfig.clear(app)
                    result.success(null)
                }
                else -> activity.get()?.handlePushMethod(call, result)
                    ?: result.error("ui_unavailable", null, null)
            }
        }
        WakeWorkerCoordinator.installChannel(app, messenger, background)
        created.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        return created
    }
}
