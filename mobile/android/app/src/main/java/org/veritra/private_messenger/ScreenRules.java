package org.veritra.private_messenger;

/** Pure rules for Android FLAG_SECURE window management, JVM-testable. */
public final class ScreenRules {
    private ScreenRules() {}

    public static final int FLAG_SECURE = 0x00002000;

    public static int applyFlags(int currentFlags, boolean secure) {
        return secure ? (currentFlags | FLAG_SECURE) : (currentFlags & ~FLAG_SECURE);
    }

    public static boolean isSecure(int currentFlags) {
        return (currentFlags & FLAG_SECURE) != 0;
    }
}
