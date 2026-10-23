package app

import (
	"context"
	"database/sql"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"runtime/metrics"
	"sync/atomic"
	"time"

	"private-messenger/server/internal/opmetrics"
)

// Capacity signals for the private /metrics endpoint (card I47). Every value
// is an instance-wide total or age. Labels come from closed sets (pool,
// volume, component, provider, scope); nothing names a user, account,
// conversation, device, token, endpoint, message, file or path.

// capacitySampleInterval bounds how stale the disk and size gauges can be.
// Sampling runs in the background so a scrape never touches the database or
// the file system.
const capacitySampleInterval = 30 * time.Second

type capacityMetrics struct {
	sampledAt     atomic.Int64 // unix seconds of the last sample; 0 before the first
	databaseBytes atomic.Int64
	walBytes      atomic.Int64
	blobBytes     atomic.Int64
	sampleErrors  atomic.Int64
	volumes       [2]volumeGauge
}

var capacityVolumes = [...]string{"database", "blobs"}

type volumeGauge struct {
	known atomic.Bool
	avail atomic.Int64
	size  atomic.Int64
}

func (a *App) runCapacitySampler(ctx context.Context) {
	a.sampleCapacity(ctx)
	ticker := time.NewTicker(capacitySampleInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			a.sampleCapacity(ctx)
		}
	}
}

// storageGranularity coarsens every byte gauge. On a small instance an exact
// size moves by one upload's ciphertext length, which would let anyone who
// sees the metrics (for example a hosted metrics service) match a known
// file. Capacity alerts need only coarse values.
const storageGranularity = 64 << 20

func coarseBytes(n int64) int64 {
	if n <= 0 {
		return 0
	}
	return n / storageGranularity * storageGranularity
}

func (a *App) sampleCapacity(ctx context.Context) {
	m := &a.metrics.capacity
	m.databaseBytes.Store(coarseBytes(fileSize(a.Config.DatabasePath)))
	m.walBytes.Store(coarseBytes(fileSize(a.Config.DatabasePath + "-wal")))
	if a.Store != nil {
		readCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		blobBytes, err := a.Store.BlobUsageBytes(readCtx)
		cancel()
		if err != nil {
			m.sampleErrors.Add(1)
			if ctx.Err() == nil {
				a.Log.Warn("capacity_sample_failed", "signal", "blob_usage")
			}
		} else {
			m.blobBytes.Store(coarseBytes(blobBytes))
		}
	}
	for i, path := range []string{filepath.Dir(a.Config.DatabasePath), a.Config.StoragePath} {
		gauge := &m.volumes[i]
		avail, size, ok := filesystemUsage(path)
		if !ok {
			gauge.known.Store(false)
			continue
		}
		gauge.avail.Store(coarseBytes(int64(min(avail, math.MaxInt64))))
		gauge.size.Store(coarseBytes(int64(min(size, math.MaxInt64))))
		gauge.known.Store(true)
	}
	m.sampledAt.Store(time.Now().Unix())
}

func fileSize(path string) int64 {
	info, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return info.Size()
}

func newPushSendHistogram() *opmetrics.Histogram {
	return opmetrics.NewHistogram(
		50*time.Millisecond, 100*time.Millisecond, 250*time.Millisecond, 500*time.Millisecond,
		time.Second, 2500*time.Millisecond, 5*time.Second, 10*time.Second,
	)
}

// writeCapacityMetrics renders the T47 signals. It reads only in-memory
// counters and the samples above.
func (m *httpMetrics) writeCapacityMetrics(w io.Writer) {
	_, _ = fmt.Fprint(w, "# TYPE veritra_process_start_time_seconds gauge\n")
	_, _ = fmt.Fprintf(w, "veritra_process_start_time_seconds %d\n", m.startedAt.Unix())
	writeRuntimeMetrics(w)

	if m.pools != nil {
		writer, reader := m.pools()
		_, _ = fmt.Fprint(w, "# TYPE veritra_sqlite_pool_waits_total counter\n")
		_, _ = fmt.Fprintf(w, "veritra_sqlite_pool_waits_total{pool=\"writer\"} %d\n", writer.WaitCount)
		_, _ = fmt.Fprintf(w, "veritra_sqlite_pool_waits_total{pool=\"reader\"} %d\n", reader.WaitCount)
		_, _ = fmt.Fprint(w, "# TYPE veritra_sqlite_pool_wait_seconds_total counter\n")
		writePoolWait(w, "writer", writer)
		writePoolWait(w, "reader", reader)
		_, _ = fmt.Fprint(w, "# TYPE veritra_sqlite_pool_in_use_connections gauge\n")
		_, _ = fmt.Fprintf(w, "veritra_sqlite_pool_in_use_connections{pool=\"writer\"} %d\n", writer.InUse)
		_, _ = fmt.Fprintf(w, "veritra_sqlite_pool_in_use_connections{pool=\"reader\"} %d\n", reader.InUse)
	}
	if m.writerAcquire != nil {
		_, _ = fmt.Fprint(w, "# TYPE veritra_sqlite_writer_acquire_duration_seconds histogram\n")
		opmetrics.WriteHistogram(w, "veritra_sqlite_writer_acquire_duration_seconds", "", m.writerAcquire())
	}

	c := &m.capacity
	if c.sampledAt.Load() > 0 {
		_, _ = fmt.Fprint(w, "# TYPE veritra_storage_sample_timestamp_seconds gauge\n")
		_, _ = fmt.Fprintf(w, "veritra_storage_sample_timestamp_seconds %d\n", c.sampledAt.Load())
		_, _ = fmt.Fprint(w, "# TYPE veritra_storage_bytes gauge\n")
		_, _ = fmt.Fprintf(w, "veritra_storage_bytes{component=\"database\"} %d\n", c.databaseBytes.Load())
		_, _ = fmt.Fprintf(w, "veritra_storage_bytes{component=\"wal\"} %d\n", c.walBytes.Load())
		_, _ = fmt.Fprintf(w, "veritra_storage_bytes{component=\"blobs\"} %d\n", c.blobBytes.Load())
		_, _ = fmt.Fprint(w, "# TYPE veritra_storage_filesystem_avail_bytes gauge\n")
		_, _ = fmt.Fprint(w, "# TYPE veritra_storage_filesystem_size_bytes gauge\n")
		for i, volume := range capacityVolumes {
			gauge := &c.volumes[i]
			if !gauge.known.Load() {
				continue
			}
			_, _ = fmt.Fprintf(w, "veritra_storage_filesystem_avail_bytes{volume=%q} %d\n", volume, gauge.avail.Load())
			_, _ = fmt.Fprintf(w, "veritra_storage_filesystem_size_bytes{volume=%q} %d\n", volume, gauge.size.Load())
		}
	}
	_, _ = fmt.Fprint(w, "# TYPE veritra_storage_sample_errors_total counter\n")
	_, _ = fmt.Fprintf(w, "veritra_storage_sample_errors_total %d\n", c.sampleErrors.Load())

	_, _ = fmt.Fprint(w, "# TYPE veritra_retention_last_sweep_timestamp_seconds gauge\n")
	_, _ = fmt.Fprintf(w, "veritra_retention_last_sweep_timestamp_seconds %d\n", m.retentionSweptAt.Load())
	_, _ = fmt.Fprint(w, "# TYPE veritra_retention_last_sweep_duration_seconds gauge\n")
	_, _ = fmt.Fprintf(w, "veritra_retention_last_sweep_duration_seconds %.3f\n", time.Duration(m.retentionSweepNanos.Load()).Seconds())

	if m.hubStats != nil {
		stats := m.hubStats()
		_, _ = fmt.Fprint(w, "# TYPE veritra_realtime_dropped_events_total counter\n")
		_, _ = fmt.Fprintf(w, "veritra_realtime_dropped_events_total %d\n", stats.DroppedEvents)
		// Draining refusals are normal during a restart; limit refusals are not.
		_, _ = fmt.Fprint(w, "# TYPE veritra_realtime_rejected_connections_total counter\n")
		_, _ = fmt.Fprintf(w, "veritra_realtime_rejected_connections_total{reason=\"limit\"} %d\n", stats.RejectedLimit)
		_, _ = fmt.Fprintf(w, "veritra_realtime_rejected_connections_total{reason=\"draining\"} %d\n", stats.RejectedDraining)
	}

	_, _ = fmt.Fprint(w, "# TYPE veritra_push_send_timeouts_total counter\n")
	for _, provider := range pushMetricProviders {
		if metric := m.push[provider]; metric != nil {
			_, _ = fmt.Fprintf(w, "veritra_push_send_timeouts_total{provider=%q} %d\n", provider, metric.timeouts.Load())
		}
	}
	_, _ = fmt.Fprint(w, "# TYPE veritra_push_backlog_oldest_job_timestamp_seconds gauge\n")
	for _, provider := range pushMetricProviders {
		if metric := m.push[provider]; metric != nil {
			_, _ = fmt.Fprintf(w, "veritra_push_backlog_oldest_job_timestamp_seconds{provider=%q} %d\n", provider, metric.oldestQueuedAt.Load())
		}
	}
	_, _ = fmt.Fprint(w, "# TYPE veritra_push_send_duration_seconds histogram\n")
	for _, provider := range pushMetricProviders {
		if metric := m.push[provider]; metric != nil && metric.sendDuration != nil {
			opmetrics.WriteHistogram(w, "veritra_push_send_duration_seconds", fmt.Sprintf("provider=%q", provider), metric.sendDuration.Snapshot())
		}
	}
}

func writePoolWait(w io.Writer, pool string, stats sql.DBStats) {
	_, _ = fmt.Fprintf(w, "veritra_sqlite_pool_wait_seconds_total{pool=%q} %.6f\n", pool, stats.WaitDuration.Seconds())
}

// writeRuntimeMetrics reports goroutines, live heap and the memory the Go
// runtime holds from the OS (mapped minus released), which is what counts
// against a container memory limit.
func writeRuntimeMetrics(w io.Writer) {
	samples := []metrics.Sample{
		{Name: "/sched/goroutines:goroutines"},
		{Name: "/gc/heap/live:bytes"},
		{Name: "/memory/classes/total:bytes"},
		{Name: "/memory/classes/heap/released:bytes"},
	}
	metrics.Read(samples)
	value := func(i int) uint64 {
		if samples[i].Value.Kind() != metrics.KindUint64 {
			return 0
		}
		return samples[i].Value.Uint64()
	}
	held := value(2)
	if released := value(3); released < held {
		held -= released
	}
	_, _ = fmt.Fprintf(w, "# TYPE veritra_go_goroutines gauge\nveritra_go_goroutines %d\n", value(0))
	_, _ = fmt.Fprintf(w, "# TYPE veritra_go_heap_live_bytes gauge\nveritra_go_heap_live_bytes %d\n", value(1))
	_, _ = fmt.Fprintf(w, "# TYPE veritra_go_memory_bytes gauge\nveritra_go_memory_bytes %d\n", held)
}
