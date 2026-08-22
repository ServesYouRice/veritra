# Native call lifecycle proposal

Status: **PROPOSED — requires explicit platform/design approval before native
manifests, entitlements, permissions, or provider changes.**

This proposal is the T42B design checkpoint. It coordinates with the server
protocol implemented by T42A and keeps the production crypto gate unchanged.

## Decision requested

Approve the following platform path for release one:

- iOS: PushKit VoIP wake plus CallKit for the system incoming/outgoing call
  surface.
- Android: a self-managed Android Telecom `ConnectionService` and
  `PhoneAccount`, with a foreground `phoneCall` service only while an active
  WebRTC call needs the microphone/camera.
- Flutter: owns encrypted signaling, WebRTC, local call UI, and the sync
  fetch/decrypt path. Native code owns only system lifecycle callbacks and
  forwards opaque call UUIDs/IDs over a method/event channel.

## Shared lifecycle

The server remains the source of truth. Its states are `ringing`, `active`,
`rejected`, `missed`, and `ended`; every transition carries the current
`expected_version` and a fresh action ID. Native callbacks never mutate the
server directly without going through the Flutter/API owner.

1. An initiator creates a two-party DM call and emits an encrypted offer.
2. The recipient receives a generic wake containing only an opaque call ID (or
   an equivalent event-available marker), never a sender name or call data.
3. The platform reports a generic incoming call surface immediately. Flutter
   then fetches sync events, verifies/decrypts the MLS signaling payload, and
   presents the local call view.
4. Answer/reject/end actions flow from the platform to Flutter, then to the
   versioned server transition. A rejected permission, stale call, failed
   decrypt, or expired call ends the native call surface without exposing
   signaling content.
5. The active WebRTC connection starts only after the user grants the
   microphone/camera permissions required for the selected media.
6. Network changes restart ICE through the existing WebRTC service; they do
   not create a second call session or bypass the server version gate.

## iOS

Use a `PKPushRegistry` configured for `PKPushType.voIP` and a `CXProvider`.
The push payload contains only an opaque call UUID/call ID and a generic
version marker. The push delegate reports a generic `CXCallUpdate` promptly;
it does not put a sender name, SDP, ICE candidate, or other signaling field in
the push. Flutter fetches and decrypts the event after wake. CallKit answer,
end, and failure callbacks are bridged to Flutter and must complete their
actions even when the fetch fails.

Required approval-time checks:

- Push Notifications and VoIP PushKit entitlements/topic configuration.
- `UIBackgroundModes` contains `voip` only for this approved VoIP path.
- Microphone and camera prompts occur when the user answers/starts media,
  with a fail-closed denied-permission state.
- The native call provider uses a generic display label such as “Veritra
  call”; identity is not inferred from the push.

References: [Responding to VoIP notifications from PushKit](https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit),
[Making and receiving VoIP calls](https://developer.apple.com/documentation/callkit/making-and-receiving-voip-calls),
and [reportNewIncomingCall](https://developer.apple.com/documentation/callkit/cxprovider/reportnewincomingcall%28with%3Aupdate%3Acompletion%3A%29).

## Android

Register one self-managed `PhoneAccount` with a stable random handle and a
`ConnectionService` protected by `BIND_TELECOM_CONNECTION_SERVICE`. A generic
FCM/UnifiedPush wake provides only the opaque call ID/event marker. The native
service calls `TelecomManager.addNewIncomingCall`, creates a generic
`Connection`, and forwards Telecom answer/reject/disconnect callbacks to
Flutter. The connection is marked self-managed and VoIP; it does not put
account IDs, names, SDP, or ICE data in Telecom extras.

Use `MANAGE_OWN_CALLS` for the self-managed account. If an active call needs a
foreground service, declare only `FOREGROUND_SERVICE` and
`FOREGROUND_SERVICE_PHONE_CALL`, use `android:foregroundServiceType="phoneCall"`,
and start it after the user accepts/starts the call. Do not start a call
foreground service from boot or use camera/microphone permissions before the
user action. The service stops after `ended`, `rejected`, permission denial,
or failed cleanup.

References: [ConnectionService](https://developer.android.com/reference/android/telecom/ConnectionService),
[Telecom framework](https://developer.android.com/develop/connectivity/telecom),
[foreground service types](https://developer.android.com/develop/background-work/services/fgs/service-types),
and [foreground-service declarations](https://developer.android.com/develop/background-work/services/fgs/declare).

## Approval boundary

No native code, manifest permission, iOS entitlement, APNs VoIP provider
change, or Android Telecom registration should be added until this proposal
is approved. Approval must also confirm that the operator can provide APNs
VoIP credentials and signed-device testing for the G24 background/terminated,
lock-screen, denied-permission, TURN, and network-change matrix.
