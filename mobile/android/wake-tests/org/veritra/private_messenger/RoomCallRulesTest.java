package org.veritra.private_messenger;

public final class RoomCallRulesTest {
    private static int checks;
    private static void check(boolean condition) { checks++; if (!condition) throw new AssertionError("room call rule check " + checks); }

    public static void main(String[] args) {
        // The type constant is the platform's own value (ServiceInfo, API 29).
        check(RoomCallRules.TYPE_MEDIA_PROJECTION == 0x20);
        // A release or profile build never starts the service, whatever Dart asks.
        check(RoomCallRules.decide(false, true, 34) == RoomCallRules.Start.BUILD_OFF);
        check(RoomCallRules.decide(false, false, 34) == RoomCallRules.Start.BUILD_OFF);
        // The only reason for a service is a screen share.
        check(RoomCallRules.decide(true, false, 34) == RoomCallRules.Start.NOTHING_REQUESTED);
        check(RoomCallRules.decide(true, true, 20) == RoomCallRules.Start.TOO_OLD);
        check(RoomCallRules.decide(true, true, 21) == RoomCallRules.Start.ALLOWED);
        check(RoomCallRules.decide(true, true, 34) == RoomCallRules.Start.ALLOWED);
        // Typed start from API 29 (SDK_Q); below it the type is not passed.
        check(RoomCallRules.serviceType(true, 34) == RoomCallRules.TYPE_MEDIA_PROJECTION);
        check(RoomCallRules.serviceType(true, 29) == RoomCallRules.TYPE_MEDIA_PROJECTION);
        check(RoomCallRules.serviceType(true, 28) == 0);
        check(RoomCallRules.serviceType(false, 34) == 0);
        // The notice names nobody and nothing about the call.
        String text = RoomCallRules.NOTIFICATION_TITLE + " " + RoomCallRules.NOTIFICATION_TEXT;
        check(!text.contains("@") && !text.toLowerCase().contains("group"));
        check(RoomCallRules.NOTIFICATION_ID != 4102); // I41's message notice
        check(!RoomCallRules.CHANNEL_ID.equals("veritra_messages"));
        check(RoomCallRules.START_TIMEOUT_MS > 0 && RoomCallRules.START_TIMEOUT_MS <= 5000); // the OS gives 5 s
        System.out.println("RoomCallRules: " + checks + " checks passed");
    }
}
