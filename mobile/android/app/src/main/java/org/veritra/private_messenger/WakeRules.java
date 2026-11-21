package org.veritra.private_messenger;

import java.util.Arrays;
import java.util.HashSet;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** Platform-independent protocol/lifetime rules, exercised with the JDK. */
public final class WakeRules {
    private WakeRules() {}
    private static Set<String> keys(String... values) { return new HashSet<>(Arrays.asList(values)); }
    public enum Payload { INVALID, LEGACY, SILENT }
    public static Payload payload(Map<String, ?> data) {
        if (!"new_encrypted_event_available".equals(data.get("event"))) return Payload.INVALID;
        if ("v1".equals(data.get("version"))) return Payload.LEGACY;
        if ("v2".equals(data.get("version")) && "none".equals(data.get("presentation")) &&
                data.keySet().equals(keys("version", "event", "presentation"))) return Payload.SILENT;
        return Payload.INVALID;
    }
    public static long nextGeneration(long sequence, long pending) {
        if (sequence < 0 || pending < 0) throw new IllegalArgumentException("invalid wake state");
        long current = Math.max(sequence, pending);
        if (current == Long.MAX_VALUE) throw new IllegalArgumentException("wake sequence exhausted");
        return current + 1;
    }
    public interface PendingStore {
        long pending();
        boolean writePending(long value);
    }
    /** Android commit(false) may already have cleared its in-memory value. */
    public static boolean acknowledge(PendingStore store, long generation) {
        long previous = store.pending();
        if (generation <= 0 || previous != generation) return false;
        if (store.writePending(0)) return true;
        // Never overwrite a newer generation, even for a non-serialized caller.
        if (store.pending() == 0) store.writePending(previous);
        return false;
    }
    public static boolean profile(String value) {
        return value != null && value.matches("[a-z][a-z0-9-]{0,39}");
    }
    /** Launch/UI facts come from native lifecycle, never metadata defaults. */
    public static Map<String, Object> bootstrap(boolean background, boolean ui, String boundProfile, boolean metadataAvailable) {
        boolean available = metadataAvailable && (boundProfile == null || profile(boundProfile));
        Map<String, Object> result = new HashMap<>();
        result.put("protocol", 1); result.put("launch", background ? "background" : "ui");
        result.put("ui_attached", ui); result.put("bound_profile", available ? boundProfile : null);
        result.put("native_silent", available); result.put("can_opt_in", false);
        return result;
    }
    /** Reply to a successful install. Opt-in is offered only after install
     * bound the profile, and only when this build allows phone notices. */
    public static Map<String, Object> installReply(boolean phoneNoticesBuild) {
        Map<String, Object> result = new HashMap<>();
        result.put("protocol", 1); result.put("native_silent", true);
        result.put("worker_attached", true); result.put("can_opt_in", phoneNoticesBuild);
        return result;
    }
    /** The fixed sentence a present method shows: the generic message
     * notice (I41) or C1's "New join request". Native words both; Dart sends
     * only the method and an opaque local notice ID. */
    public enum Notice { MESSAGE, JOIN_REQUEST }
    /** The exact argument keys of a permit-bound method, or null when the
     * method is not one. */
    public static Set<String> permitArguments(String method) {
        if ("validatePermit".equals(method)) return keys("protocol", "permit", "profile");
        if (notice(method) != null) return keys("protocol", "permit", "profile", "notice_id");
        return null;
    }
    public static Notice notice(String method) {
        if ("presentGenericNotice".equals(method)) return Notice.MESSAGE;
        if ("presentJoinRequestNotice".equals(method)) return Notice.JOIN_REQUEST;
        return null;
    }
    public static boolean noticeId(String value) {
        return value != null && value.matches("[0-9a-f]{32}");
    }
    /** Each message notice has its own notification; join-request notices
     * share one, so a newer one replaces an older one instead of stacking
     * identical lines. */
    public static final int JOIN_REQUEST_NOTIFICATION_ID = 4104;
    public static int notificationId(Notice notice, String noticeId) {
        if (notice == null || !noticeId(noticeId)) throw new IllegalArgumentException("invalid notice");
        if (notice == Notice.JOIN_REQUEST) return JOIN_REQUEST_NOTIFICATION_ID;
        return (int) Long.parseLong(noticeId.substring(0, 8), 16);
    }
    public enum NoticeClaim { NEW, DUPLICATE, FULL, CLOCK_ROLLBACK }
    public static final int MAX_NOTICE_ENTRIES = 4096;
    public static final long NOTICE_RETENTION_MS = 60L * 60 * 1000;
    /** Mutate a journal copy, then persist it BEFORE any OS notification call. */
    public static NoticeClaim claimNotice(Map<String, Long> entries, long clock, long now, String key) {
        if (clock < 0 || now < 0 || entries.size() > MAX_NOTICE_ENTRIES) throw new IllegalArgumentException("invalid notice journal");
        if (now < clock) return NoticeClaim.CLOCK_ROLLBACK;
        for (long time : entries.values()) if (time < 0 || time > clock) throw new IllegalArgumentException("invalid notice journal");
        java.util.Iterator<Map.Entry<String, Long>> iterator = entries.entrySet().iterator();
        while (iterator.hasNext()) if (now - iterator.next().getValue() > NOTICE_RETENTION_MS) iterator.remove();
        if (entries.containsKey(key)) return NoticeClaim.DUPLICATE;
        if (entries.size() >= MAX_NOTICE_ENTRIES) return NoticeClaim.FULL;
        entries.put(key, now);
        return NoticeClaim.NEW;
    }
    public static final class Permit {
        public final String id = UUID.randomUUID().toString();
        public final String profile;
        public final long generation;
        private final long startedAt, deadline;
        private boolean revoked;
        public Permit(String profile, long generation, long startedAt, long budgetMs) {
            if (!profile(profile) || generation <= 0 || budgetMs < 1 || budgetMs > 20000 || startedAt < 0)
                throw new IllegalArgumentException("invalid wake permit");
            this.profile = profile; this.generation = generation; this.startedAt = startedAt;
            if (startedAt > Long.MAX_VALUE - budgetMs) throw new IllegalArgumentException("invalid deadline");
            this.deadline = startedAt + budgetMs;
        }
        public long remaining(long now) { return revoked || now < startedAt ? 0 : Math.max(0, deadline - now); }
        public void revoke() { revoked = true; }
        public boolean matches(String id, String profile, long now) {
            return this.id.equals(id) && this.profile.equals(profile) && remaining(now) > 0;
        }
        public boolean durableOutcome(Map<?, ?> result, long now) {
            if (remaining(now) == 0 || !result.keySet().equals(keys("protocol", "permit", "profile", "wake_generation", "outcome"))) return false;
            Object protocol = result.get("protocol"), generation = result.get("wake_generation");
            return protocol instanceof Integer && ((Integer) protocol) == 1 &&
                (generation instanceof Integer || generation instanceof Long) && ((Number) generation).longValue() == this.generation &&
                this.id.equals(result.get("permit")) && this.profile.equals(result.get("profile")) &&
                ("committed".equals(result.get("outcome")) || "no_change".equals(result.get("outcome")));
        }
    }
}
