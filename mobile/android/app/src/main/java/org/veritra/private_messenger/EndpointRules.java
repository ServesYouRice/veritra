package org.veritra.private_messenger;

/** Pure rules for the pending push endpoint record, JVM-testable. */
public final class EndpointRules {
    private EndpointRules() {}

    /** Generations only grow; overflow fails closed instead of wrapping. */
    public static long nextGeneration(long sequence) {
        if (sequence < 0 || sequence == Long.MAX_VALUE) throw new IllegalArgumentException("endpoint sequence");
        return sequence + 1;
    }
}
