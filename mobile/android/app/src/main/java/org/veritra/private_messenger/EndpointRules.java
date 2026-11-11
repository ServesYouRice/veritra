package org.veritra.private_messenger;

/** Pure rules for the pending push endpoint record, JVM-testable. */
public final class EndpointRules {
    private EndpointRules() {}

    /** Select from durable registration state, including after process restart. */
    public static String distributorProvider(String instance, String storedInstance, String provider) {
        return instance.equals(storedInstance) && "unifiedpush".equals(provider)
            ? "unifiedpush" : "webpush";
    }

    /** Generations only grow; overflow fails closed instead of wrapping. */
    public static long nextGeneration(long sequence) {
        if (sequence < 0 || sequence == Long.MAX_VALUE) throw new IllegalArgumentException("endpoint sequence");
        return sequence + 1;
    }
}
