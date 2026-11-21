package org.veritra.private_messenger;

/**
 * Pure rules for the foreground service a screen share in a group call needs
 * (B6, docs/designs/B6-group-calls.md "Mobile and desktop constraints"),
 * JVM-testable. Android 14 and later refuse a screen capture unless a
 * foreground service of type mediaProjection runs, and the service may start
 * only after the user accepted the capture consent (the Dart side orders
 * that). Only the mediaProjection type is declared: the microphone and the
 * camera need no service while the app is in the foreground (O5).
 */
public final class RoomCallRules {
    private RoomCallRules() {}

    /** ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION. */
    public static final int TYPE_MEDIA_PROJECTION = 0x00000020;
    /** First API with a typed startForeground and ServiceInfo types. */
    public static final int SDK_Q = 29;
    /** MediaProjection needs API 21; Flutter's minimum is higher. */
    public static final int SDK_MEDIA_PROJECTION = 21;

    public static final int NOTIFICATION_ID = 4104;
    public static final String CHANNEL_ID = "veritra_room_call";
    /** Fixed text, like the I41 message notice: no names, no conversation. */
    public static final String NOTIFICATION_TITLE = "Veritra";
    public static final String NOTIFICATION_TEXT = "Sharing your screen in a call";

    /** How long the app waits for the service to report that it is running. */
    public static final long START_TIMEOUT_MS = 3000;

    public enum Start { ALLOWED, BUILD_OFF, NOTHING_REQUESTED, TOO_OLD }

    /**
     * Whether a service may start. [buildEnabled] is the BuildConfig flag,
     * decided at build time (demo builds only), never taken from Dart.
     */
    public static Start decide(boolean buildEnabled, boolean mediaProjection, int sdk) {
        if (!buildEnabled) return Start.BUILD_OFF;
        if (!mediaProjection) return Start.NOTHING_REQUESTED;
        if (sdk < SDK_MEDIA_PROJECTION) return Start.TOO_OLD;
        return Start.ALLOWED;
    }

    /** The type bits for startForeground, or 0 when the platform takes none. */
    public static int serviceType(boolean mediaProjection, int sdk) {
        return mediaProjection && sdk >= SDK_Q ? TYPE_MEDIA_PROJECTION : 0;
    }
}
