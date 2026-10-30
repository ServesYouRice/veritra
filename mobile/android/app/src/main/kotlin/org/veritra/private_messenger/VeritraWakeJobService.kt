package org.veritra.private_messenger

import android.app.job.JobParameters
import android.app.job.JobService
import android.os.SystemClock

class VeritraWakeJobService : JobService() {
    private var running: JobParameters? = null
    override fun onStartJob(params: JobParameters): Boolean {
        running = params
        val startedAt = SystemClock.elapsedRealtime()
        android.os.Handler(mainLooper).post {
            if (running === params) WakeWorkerCoordinator.run(applicationContext, startedAt) { retry ->
                if (running === params) { running = null; jobFinished(params, retry) }
            }
        }
        return true
    }
    override fun onStopJob(params: JobParameters): Boolean {
        if (running === params) {
            running = null
            WakeWorkerCoordinator.cancel("os_stop", notify = false)
        }
        return true
    }
}
