package org.veritra.private_messenger;

import java.util.HashMap;
import java.util.Map;

public final class WakeRulesTest {
    private static int checks;
    private static void check(boolean condition) { checks++; if (!condition) throw new AssertionError("wake protocol check " + checks); }
    private static final class CommitStore implements WakeRules.PendingStore {
        long memory = 9, disk = 9;
        int failures;
        public long pending() { return memory; }
        public boolean writePending(long value) {
            memory = value; // SharedPreferences applies memory before disk.
            if (failures-- > 0) return false;
            disk = value; return true;
        }
    }
    public static void main(String[] args) {
        Map<String, Object> silent = new HashMap<>();
        silent.put("version", "v2"); silent.put("event", "new_encrypted_event_available"); silent.put("presentation", "none");
        check(WakeRules.payload(silent) == WakeRules.Payload.SILENT);
        silent.put("sender", "forbidden"); check(WakeRules.payload(silent) == WakeRules.Payload.INVALID);
        silent.remove("sender"); silent.put("presentation", "alert"); check(WakeRules.payload(silent) == WakeRules.Payload.INVALID);
        silent.remove("presentation"); check(WakeRules.payload(silent) == WakeRules.Payload.INVALID);
        silent.put("version", "v1"); check(WakeRules.payload(silent) == WakeRules.Payload.LEGACY);
        check(WakeRules.nextGeneration(8, 0) == 9); // ACK removed pending only.
        check(WakeRules.nextGeneration(8, 9) == 10);
        CommitStore store = new CommitStore(); store.failures = 1;
        check(!WakeRules.acknowledge(store, 9));
        check(store.memory == 9 && store.disk == 9);
        check(WakeRules.acknowledge(store, 9)); check(store.memory == 0 && store.disk == 0);
        store.memory = 10; store.disk = 10;
        check(!WakeRules.acknowledge(store, 9)); check(store.memory == 10 && store.disk == 10);
        store.memory = 9; store.disk = 9; store.failures = 2;
        check(!WakeRules.acknowledge(store, 9)); check(store.memory == 9 && store.disk == 9);
        try { WakeRules.nextGeneration(Long.MAX_VALUE, 0); throw new AssertionError(); }
        catch (IllegalArgumentException expected) { checks++; }
        check(!WakeRules.profile("../demo")); check(!WakeRules.profile("demo\n"));
        Map<String, Object> uiBootstrap = WakeRules.bootstrap(false, true, "demo", false);
        check("ui".equals(uiBootstrap.get("launch"))); check(Boolean.TRUE.equals(uiBootstrap.get("ui_attached")));
        check(uiBootstrap.get("bound_profile") == null); check(Boolean.FALSE.equals(uiBootstrap.get("native_silent")));
        Map<String, Object> coldBootstrap = WakeRules.bootstrap(true, false, "demo", false);
        check("background".equals(coldBootstrap.get("launch"))); check(Boolean.FALSE.equals(coldBootstrap.get("native_silent")));
        check(Boolean.FALSE.equals(coldBootstrap.get("can_opt_in")));
        WakeRules.Permit p = new WakeRules.Permit("demo", 9, 100, 20000);
        check(p.matches(p.id, "demo", 101)); check(!p.matches(p.id, "other", 101));
        check(p.remaining(20100) == 0); check(p.remaining(99) == 0);
        Map<String, Object> result = new HashMap<>();
        result.put("protocol", 1); result.put("permit", p.id); result.put("profile", "demo");
        result.put("wake_generation", 9L); result.put("outcome", "committed");
        check(p.durableOutcome(result, 102));
        result.put("wake_generation", 9.5); check(!p.durableOutcome(result, 102));
        result.put("wake_generation", 8L); check(!p.durableOutcome(result, 102));
        result.put("wake_generation", 9L); result.put("outcome", "retry"); check(!p.durableOutcome(result, 102));
        result.put("outcome", "no_change"); check(p.durableOutcome(result, 102));
        check(!p.durableOutcome(result, 20100));
        result.put("plaintext", "forbidden"); check(!p.durableOutcome(result, 102)); result.remove("plaintext");
        p.revoke(); check(!p.matches(p.id, "demo", 102)); check(!p.durableOutcome(result, 102));
        Map<String, Long> notices = new HashMap<>();
        check(WakeRules.claimNotice(notices, 0, 100, "demo:first") == WakeRules.NoticeClaim.NEW);
        // Model crash after durable claim but before OS scheduling, then reload.
        notices = new HashMap<>(notices);
        check(WakeRules.claimNotice(notices, 100, 101, "demo:first") == WakeRules.NoticeClaim.DUPLICATE);
        check(WakeRules.claimNotice(notices, 101, 100, "demo:new") == WakeRules.NoticeClaim.CLOCK_ROLLBACK);
        for (int i = notices.size(); i < WakeRules.MAX_NOTICE_ENTRIES; i++) notices.put("demo:" + i, 100L);
        check(WakeRules.claimNotice(notices, 101, 102, "demo:new") == WakeRules.NoticeClaim.FULL);
        check(notices.containsKey("demo:first")); // Fresh decisions never evicted.
        check(WakeRules.claimNotice(notices, 102, WakeRules.NOTICE_RETENTION_MS + 1000, "demo:new") == WakeRules.NoticeClaim.NEW);
        System.out.println("WakeRules: " + checks + " checks passed");
    }
}
