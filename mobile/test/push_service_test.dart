import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/push/push_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannelName = 'org.veritra.private_messenger/push_methods';
  const eventChannelName = 'org.veritra.private_messenger/push_events';
  const codec = StandardMethodCodec();

  // PlatformMobilePushService subscribes to the event channel in its
  // constructor. An unmocked EventChannel turns the 'listen' call into a
  // MissingPluginException reported through FlutterError.reportError, which
  // flutter_test escalates into a test failure.
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(eventChannelName),
            (MethodCall call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(eventChannelName), null);
  });

  group('DisabledMobilePushService', () {
    test('provides no-op implementations and safe defaults', () async {
      final disabled = DisabledMobilePushService();
      expect(await disabled.events.isEmpty, isTrue);
      await disabled.register(
          instance: 'https://example.com', vapid: 'test_vapid');
      await disabled.pickDistributor();
      await disabled.unregister('https://example.com');
      expect(await disabled.pendingWakeGeneration(), 0);
      expect(await disabled.acknowledgeWake(1), isFalse);
      disabled.dispose();
    });
  });

  group('PlatformMobilePushService method channel calls', () {
    final methodCalls = <MethodCall>[];
    Object? methodResult;

    setUp(() {
      methodCalls.clear();
      methodResult = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(methodChannelName),
              (MethodCall call) async {
        methodCalls.add(call);
        return methodResult;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel(methodChannelName), null);
    });

    test('register invokes method channel with instance and vapid', () async {
      final service = PlatformMobilePushService();
      addTearDown(service.dispose);

      await service.register(
          instance: 'https://example.com', vapid: 'vapid_key');
      expect(methodCalls, hasLength(1));
      expect(methodCalls.first.method, 'register');
      expect(methodCalls.first.arguments, {
        'instance': 'https://example.com',
        'vapid': 'vapid_key',
      });
    });

    test('pickDistributor invokes method channel without arguments', () async {
      final service = PlatformMobilePushService();
      addTearDown(service.dispose);

      await service.pickDistributor();
      expect(methodCalls, hasLength(1));
      expect(methodCalls.first.method, 'pickDistributor');
    });

    test('unregister invokes method channel with instance', () async {
      final service = PlatformMobilePushService();
      addTearDown(service.dispose);

      await service.unregister('https://example.com');
      expect(methodCalls, hasLength(1));
      expect(methodCalls.first.method, 'unregister');
      expect(methodCalls.first.arguments, {'instance': 'https://example.com'});
    });

    test('pendingWakeGeneration returns parsed int and handles non-numbers',
        () async {
      final service = PlatformMobilePushService();
      addTearDown(service.dispose);

      methodResult = 42;
      expect(await service.pendingWakeGeneration(), 42);

      methodResult = 7.0;
      expect(await service.pendingWakeGeneration(), 7);

      methodResult = 'not_a_number';
      expect(await service.pendingWakeGeneration(), 0);

      methodResult = null;
      expect(await service.pendingWakeGeneration(), 0);
    });

    test(
        'acknowledgeWake rejects non-positive generations without invoking native',
        () async {
      final service = PlatformMobilePushService();
      addTearDown(service.dispose);

      expect(await service.acknowledgeWake(0), isFalse);
      expect(await service.acknowledgeWake(-1), isFalse);
      expect(methodCalls, isEmpty);

      methodResult = true;
      expect(await service.acknowledgeWake(5), isTrue);
      expect(methodCalls, hasLength(1));
      expect(methodCalls.first.method, 'acknowledgeWake');
      expect(methodCalls.first.arguments, {'generation': 5});
    });
  });

  group('PlatformMobilePushService event channel decoding', () {
    Future<void> sendEvent(Object? event) async {
      final ByteData? data = codec.encodeSuccessEnvelope(event);
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(eventChannelName, data, (ByteData? reply) {});
    }

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(methodChannelName),
              (MethodCall call) async => null);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel(methodChannelName), null);
    });

    test('decodes valid endpoint, wake, and unregistered events', () async {
      final service = PlatformMobilePushService();
      final received = <PushEvent>[];
      final subscription = service.events.listen(received.add);

      await sendEvent({
        'type': 'endpoint',
        'instance': 'https://node.example.com',
        'provider': 'fcm',
        'endpoint': 'https://fcm.googleapis.com/fcm/send/token',
        'publicKey': 'pubkey123',
        'authSecret': 'secret456',
      });

      await sendEvent({'type': 'wake'});

      await sendEvent({
        'type': 'unregistered',
        'instance': 'https://node.example.com',
      });

      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(3));

      expect(received[0], isA<PushEndpointEvent>());
      final endpointEvent = received[0] as PushEndpointEvent;
      expect(endpointEvent.instance, 'https://node.example.com');
      expect(endpointEvent.provider, 'fcm');
      expect(
          endpointEvent.endpoint, 'https://fcm.googleapis.com/fcm/send/token');
      expect(endpointEvent.publicKey, 'pubkey123');
      expect(endpointEvent.authSecret, 'secret456');

      expect(received[1], isA<PushWakeEvent>());

      expect(received[2], isA<PushUnregisteredEvent>());
      final unregEvent = received[2] as PushUnregisteredEvent;
      expect(unregEvent.instance, 'https://node.example.com');

      await subscription.cancel();
      service.dispose();
    });

    test('ignores malformed, unknown, and non-map events safely', () async {
      final service = PlatformMobilePushService();
      final received = <PushEvent>[];
      final subscription = service.events.listen(received.add);

      await sendEvent('not_a_map');
      await sendEvent(<Object?>[]);
      await sendEvent({'type': 'unknown_type'});
      await sendEvent({'type': 'endpoint', 'instance': 123}); // wrong types
      await sendEvent({'type': 'unregistered'}); // missing instance

      await Future<void>.delayed(Duration.zero);
      expect(received, isEmpty);

      await subscription.cancel();
      service.dispose();
    });
  });
}
