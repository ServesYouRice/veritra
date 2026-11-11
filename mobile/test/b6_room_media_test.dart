import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:private_messenger/calls/room/room_engine.dart';
import 'package:private_messenger/calls/room/room_factory.dart';
import 'package:private_messenger/calls/room/room_media.dart';
import 'package:private_messenger/calls/room/room_ports.dart';
import 'package:private_messenger/calls/room/webrtc_frame_keys.dart';

import 'b6_room_fakes.dart';

// B6 media transport against fakes of the SFU, the frame cryptor and its key
// provider: fail-closed publish order, receive binding by sealed
// announcements only, and the factory's fail-closed open.

class FakeKeyProvider implements rtc.KeyProvider {
  final Map<String, Uint8List> keys = {};
  bool refuse = false;
  bool disposed = false;
  final List<String> log;
  FakeKeyProvider(this.log);

  @override
  String get id => 'kp';

  @override
  Future<bool> setKey(
      {required String participantId,
      required int index,
      required Uint8List key}) async {
    if (refuse) return false;
    keys['$participantId@$index'] = Uint8List.fromList(key);
    log.add('key $participantId@$index');
    return true;
  }

  @override
  Future<void> dispose() async => disposed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeCryptor implements RoomFrameCryptor {
  FakeCryptor(this.participantId, this.log, {this.failEnable = false});
  final String participantId;
  final List<String> log;
  final bool failEnable;
  bool enabled = false;
  bool disposed = false;
  int? keyIndex;

  @override
  Future<bool> setEnabled(bool on) async {
    log.add('cryptor $participantId enabled=$on');
    if (failEnable && on) return false;
    enabled = on;
    return true;
  }

  @override
  Future<bool> setKeyIndex(int index) async {
    log.add('cryptor $participantId index=$index');
    keyIndex = index;
    return true;
  }

  @override
  Future<void> dispose() async {
    log.add('cryptor $participantId disposed');
    disposed = true;
  }
}

class FakeLocalTrack implements SfuLocalTrack {
  FakeLocalTrack(this.sid, this.slot, this.log);
  @override
  final String sid;
  @override
  final int slot;
  final List<String> log;
  bool enabled = false;
  @override
  Future<void> setEnabled(bool on) async {
    enabled = on;
    log.add('track $sid enabled=$on');
  }
}

class FakeRemoteTrack implements SfuRemoteTrack {
  FakeRemoteTrack(this.sid, this.participant);
  @override
  final String sid;
  @override
  final String participant;
  bool playing = true; // what a raw subscription would do
  bool unsubscribed = false;
  bool refusesMute = false;
  @override
  Future<void> setPlaying(bool on) async {
    if (!on && refusesMute) throw StateError('cannot mute');
    playing = on;
  }

  @override
  Future<void> unsubscribe() async => unsubscribed = true;
}

class FakeHub {
  final List<FakeSfu> live = [];
}

class FakeSfu implements SfuConnection {
  FakeSfu(this.hub, this.identity);
  final FakeHub hub;
  final String identity;
  final List<String> log = [];
  final StreamController<SfuEvent> _events = StreamController.broadcast();
  final List<FakeLocalTrack> published = [];
  final Map<String, FakeRemoteTrack> remote = {};
  final List<FakeCryptor> cryptors = [];
  final List<Uint8List> sent = [];
  bool failSenderEnable = false;
  bool failReceiverEnable = false;
  bool connected = false;

  void emit(SfuEvent event) => _events.add(event);

  @override
  Stream<SfuEvent> get events => _events.stream;

  @override
  String? get localIdentity => connected ? identity : null;

  @override
  Future<void> connect(String url, String token) async {
    log.add('connect');
    connected = true;
    hub.live.add(this);
    for (final other in hub.live) {
      if (other == this) continue;
      for (final track in other.published) {
        _subscribe(track.sid, other.identity);
      }
    }
  }

  void _subscribe(String sid, String from) {
    final track = remote[sid] = FakeRemoteTrack(sid, from);
    emit(SfuTrackSubscribed(track));
  }

  @override
  Future<SfuLocalTrack> publishDisabled(int slot) async {
    log.add('publish $slot');
    final track = FakeLocalTrack('TR_${identity}_$slot', slot, log);
    published.add(track);
    for (final other in hub.live) {
      if (other != this) other._subscribe(track.sid, identity);
    }
    return track;
  }

  @override
  Future<void> unpublish(SfuLocalTrack track) async =>
      log.add('unpublish ${track.sid}');

  @override
  Future<RoomFrameCryptor> senderCryptor(
      SfuLocalTrack track, String participantId) async {
    log.add('sender cryptor $participantId');
    final c = FakeCryptor(participantId, log, failEnable: failSenderEnable);
    cryptors.add(c);
    return c;
  }

  @override
  Future<RoomFrameCryptor> receiverCryptor(
      SfuRemoteTrack track, String participantId) async {
    log.add('receiver cryptor ${track.sid} $participantId');
    final c = FakeCryptor(participantId, log, failEnable: failReceiverEnable);
    cryptors.add(c);
    return c;
  }

  @override
  Future<void> sendData(Uint8List data) async {
    sent.add(data);
    for (final other in hub.live) {
      if (other != this) other.emit(SfuData(identity, data));
    }
  }

  @override
  Future<void> disconnect() async {
    log.add('disconnect');
    hub.live.remove(this);
  }

  FakeCryptor? receiverFor(String sid) => cryptors
      .where((c) =>
          !c.disposed &&
          log.contains('receiver cryptor $sid ${c.participantId}'))
      .lastOrNull;
}

class MediaDevice {
  MediaDevice._(this.self, this.crypto, this.api, this.keys, this.provider,
      this.engine, this.sfu, this.media);
  final CallMember self;
  final FakeCrypto crypto;
  final FakeApi api;
  final WebRtcFrameKeys keys;
  final FakeKeyProvider provider;
  final RoomEngine engine;
  final FakeSfu sfu;
  final RoomMediaSession media;

  static Future<MediaDevice> create(String name, FakeServer server,
      FakeClock clock, FakeParent parent, FakeHub hub) async {
    final self = member(name);
    final crypto = FakeCrypto(self);
    final api = FakeApi(server, self);
    final log = <String>[];
    final provider = FakeKeyProvider(log);
    final keys = await WebRtcFrameKeys.open(create: (_) async => provider);
    final engine = RoomEngine(
      api: api,
      crypto: crypto,
      parent: parent,
      keys: keys,
      scheduler: clock,
      selfAccountId: self.accountId,
      selfDeviceId: self.deviceId,
    );
    final sfu = FakeSfu(hub, 'sfu_$name');
    final media = RoomMediaSession(engine: engine, keys: keys, sfu: sfu)
      ..start();
    return MediaDevice._(self, crypto, api, keys, provider, engine, sfu, media);
  }

  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await pump();
      await keys.idle;
      await media.idle;
    }
  }
}

void main() {
  late FakeServer server;
  late FakeClock clock;
  late FakeParent parent;
  late FakeHub hub;

  setUp(() {
    server = FakeServer('conv_1');
    clock = FakeClock();
    parent = FakeParent([member('a'), member('b'), member('c')]);
    hub = FakeHub();
  });

  Future<MediaDevice> start(String name) async {
    final d = await MediaDevice.create(name, server, clock, parent, hub);
    await d.engine.join('conv_1');
    await d.settle();
    return d;
  }

  Future<void> admit(MediaDevice existing, MediaDevice joiner,
      {List<MediaDevice> others = const []}) async {
    existing.engine.refresh();
    await existing.settle();
    await clock.advance(const Duration(milliseconds: 250));
    await existing.settle();
    joiner.engine.refresh();
    await joiner.settle();
    for (final d in others) {
      d.engine.refresh();
      await d.settle();
    }
    // Announcements cross the hub after every epoch change.
    for (final d in [existing, joiner, ...others]) {
      await d.settle();
    }
  }

  Future<void> end(List<MediaDevice> devices) async {
    for (final d in devices) {
      await d.media.close();
      d.engine.dispose();
    }
  }

  test('the key provider gets exactly the fail-closed options', () async {
    rtc.KeyProviderOptions? seen;
    final log = <String>[];
    await WebRtcFrameKeys.open(create: (options) async {
      seen = options;
      return FakeKeyProvider(log);
    });
    final options = seen!;
    expect(options.discardFrameWhenCryptorNotReady, isTrue);
    expect(options.sharedKey, isFalse);
    expect(options.keyDerivationAlgorithm, rtc.KeyDerivationAlgorithm.kHKDF);
    expect(options.ratchetWindowSize, 0);
    expect(options.uncryptedMagicBytes, isNull);
    expect(options.keyRingSize, 16);
    expect(options.ratchetSalt, b6FrameSalt);
    expect(options.toJson().containsKey('uncryptedMagicBytes'), isFalse);
  });

  test('no fail-closed key provider means no call', () async {
    await expectLater(
        WebRtcFrameKeys.open(
            settings: const RoomCryptorSettings(useMagicBytes: true),
            create: (_) async => FakeKeyProvider([])),
        throwsA(isA<FrameEncryptionUnavailable>()));
    await expectLater(
        WebRtcFrameKeys.open(
            create: (_) async => throw UnsupportedError('no frame cryptor')),
        throwsA(isA<FrameEncryptionUnavailable>()));
  });

  test('voice is published disabled, then encrypted and keyed, then enabled',
      () async {
    final a = await start('a');
    expect(a.engine.phase, RoomPhase.active);
    final log = a.sfu.log;
    final publish = log.indexOf('publish 0');
    final cryptor = log.indexOf('sender cryptor acct_a/dev_a:0');
    final enabled = log.indexOf('cryptor acct_a/dev_a:0 enabled=true');
    final index = log.indexOf('cryptor acct_a/dev_a:0 index=0');
    final open = log.indexOf('track TR_sfu_a_0 enabled=true');
    expect(publish, greaterThanOrEqualTo(0));
    expect(cryptor, greaterThan(publish));
    expect(enabled, greaterThan(cryptor));
    expect(index, greaterThan(enabled));
    expect(open, greaterThan(index),
        reason: 'the capture opens only once a key index is set');
    expect(a.provider.keys.containsKey('acct_a/dev_a:0@0'), isTrue);
    expect(a.sfu.published.single.enabled, isTrue);
    await end([a]);
  });

  test('a sender cryptor that will not enable ends the call, never sends',
      () async {
    final self = member('a');
    final provider = FakeKeyProvider([]);
    final keys = await WebRtcFrameKeys.open(create: (_) async => provider);
    final engine = RoomEngine(
      api: FakeApi(server, self),
      crypto: FakeCrypto(self),
      parent: parent,
      keys: keys,
      scheduler: clock,
      selfAccountId: self.accountId,
      selfDeviceId: self.deviceId,
    );
    final sfu = FakeSfu(hub, 'sfu_a')..failSenderEnable = true;
    final media = RoomMediaSession(engine: engine, keys: keys, sfu: sfu)
      ..start();
    await engine.join('conv_1');
    for (var i = 0; i < 4; i++) {
      await pump();
      await media.idle;
    }
    expect(engine.phase, RoomPhase.failed);
    expect(engine.failure, RoomFailure.cryptorNotFailClosed);
    expect(
        sfu.log
            .where((l) => l.contains('enabled=true') && l.startsWith('track')),
        isEmpty);
    expect(sfu.log, contains('disconnect'));
    engine.dispose();
  });

  test('a key the provider refuses ends the call', () async {
    final a = await start('a');
    a.provider.refuse = true;
    final b2 = await start('b');
    await admit(a, b2);
    await a.settle();
    expect(a.engine.phase, RoomPhase.failed);
    expect(a.engine.failure, RoomFailure.cryptorNotFailClosed);
    await end([b2]);
    a.engine.dispose();
  });

  test('a remote track binds only through its sender\'s sealed announcement',
      () async {
    final a = await start('a');
    final b2 = await start('b');
    // Before b is in the call group, a already receives b's SFU track: it
    // gets a receiver cryptor with no key and stays silent.
    final early = a.sfu.remote['TR_sfu_b_0'];
    if (early != null) {
      expect(early.playing, isFalse);
      expect(a.media.boundTracks, isEmpty);
    }
    await admit(a, b2);
    final track = a.sfu.remote['TR_sfu_b_0']!;
    expect(a.media.boundTracks, {'TR_sfu_b_0': 'acct_b/dev_b:0'});
    expect(track.playing, isTrue);
    // One receiver cryptor per track, keyed by its alias, which holds b's
    // voice key of this epoch.
    expect(a.sfu.receiverFor('TR_sfu_b_0')!.participantId, 'rx:TR_sfu_b_0');
    expect(a.sfu.receiverFor('TR_sfu_b_0')!.enabled, isTrue);
    expect(a.provider.keys['rx:TR_sfu_b_0@1'], isNotNull);
    expect(a.provider.keys['rx:TR_sfu_b_0@1'],
        a.provider.keys['acct_b/dev_b:0@1']);
    expect(b2.media.boundTracks, {'TR_sfu_a_0': 'acct_a/dev_a:0'});
    // The data the SFU carried names no account or device.
    for (final data in [...a.sfu.sent, ...b2.sfu.sent]) {
      expect(s(data.sublist(0, RoomEngine.signalMagic.length + 10)),
          isNot(contains('acct_')));
    }
    await end([a, b2]);
  });

  test('an announcement from the wrong SFU identity or the SFU binds nothing',
      () async {
    final a = await start('a');
    final b2 = await start('b');
    await admit(a, b2);
    expect(a.media.boundTracks['TR_sfu_b_0'], 'acct_b/dev_b:0');
    // The SFU claims a track of another connection under b's announced id:
    // the announcement names b's connection, so it stays unbound and silent.
    final claimed = FakeRemoteTrack('TR_sfu_b_0', 'sfu_c');
    a.sfu.emit(SfuTrackSubscribed(claimed));
    await a.settle();
    expect(a.media.boundTracks, isEmpty);
    expect(claimed.playing, isFalse);
    // b's genuine announcement replayed from another connection, or as the
    // SFU's own data, binds nothing to that connection.
    final genuine = b2.sfu.sent.last;
    a.sfu.emit(SfuData('sfu_c', genuine));
    a.sfu.emit(SfuData(null, genuine));
    a.sfu.emit(SfuData('sfu_c', b('VB6S not sealed')));
    await a.settle();
    expect(a.media.boundTracks, isEmpty);
    expect(claimed.playing, isFalse);
    // The claimed track's cryptor holds no key of b's.
    final cryptors = a.sfu.cryptors
        .where((c) => c.participantId == 'rx:TR_sfu_b_0' && !c.disposed);
    expect(cryptors, hasLength(1));
    expect(a.provider.keys['rx:TR_sfu_b_0@1'],
        isNot(a.provider.keys['acct_b/dev_b:0@1']));
    await end([a, b2]);
  });

  test('a member removed from the parent loses its track binding', () async {
    final a = await start('a');
    final b2 = await start('b');
    await admit(a, b2);
    expect(a.media.boundTracks['TR_sfu_b_0'], 'acct_b/dev_b:0');
    parent.list.removeWhere((m) => m.id == b2.self.id);
    a.engine.refresh();
    await a.settle();
    await clock.advance(const Duration(milliseconds: 250));
    await a.settle();
    expect(a.engine.roster.map((m) => m.id), ['acct_a/dev_a']);
    expect(a.media.boundTracks, isEmpty);
    expect(a.sfu.remote['TR_sfu_b_0']!.playing, isFalse,
        reason: 'frames from a removed member are never played');
    await end([a, b2]);
  });

  // Review MEDIUM (round 7): the receiver cryptor was disposed and created
  // again on the same RTP receiver at every bind. Now one per track, and
  // binding moves keys, not cryptors.
  test(
      'one receiver cryptor per track through bind, epoch change and unbind; '
      'keys follow the binding', () async {
    final a = await start('a');
    final b2 = await start('b');
    await admit(a, b2);
    int made() => a.sfu.log
        .where((l) => l.startsWith('receiver cryptor TR_sfu_b_0 '))
        .length;
    Uint8List? at(String id, int index) => a.provider.keys['$id@$index'];
    const rx = 'rx:TR_sfu_b_0';
    expect(a.media.boundTracks['TR_sfu_b_0'], 'acct_b/dev_b:0');
    expect(made(), 1);
    expect(at(rx, 1), at('acct_b/dev_b:0', 1));
    // c joins: a new epoch's key is mirrored, and ten seconds later the old
    // one is gone from the alias as from b's own slot.
    final c = await start('c');
    await admit(a, c, others: [b2]);
    expect(a.engine.epoch, 2);
    expect(at(rx, 2), at('acct_b/dev_b:0', 2));
    final before = Uint8List.fromList(at(rx, 1)!);
    await clock.advance(const Duration(seconds: 11));
    await a.settle();
    expect(at(rx, 1), isNot(before), reason: 'the 10 s wipe covers it');
    expect(at(rx, 1), isNot(at('acct_b/dev_b:0', 2)));
    expect(made(), 1);
    // b leaves the parent: unbound, its keys junk at once, same cryptor.
    final key2 = Uint8List.fromList(at(rx, 2)!);
    parent.list.removeWhere((m) => m.id == b2.self.id);
    a.engine.refresh();
    await a.settle();
    await clock.advance(const Duration(milliseconds: 250));
    await a.settle();
    expect(a.media.boundTracks.containsKey('TR_sfu_b_0'), isFalse);
    expect(a.sfu.remote['TR_sfu_b_0']!.playing, isFalse);
    expect(at(rx, 2), isNot(key2));
    expect(at(rx, 3), isNull, reason: 'nothing mirrored after the unbind');
    expect(made(), 1);
    expect(a.sfu.receiverFor('TR_sfu_b_0')!.disposed, isFalse);
    // c's track was bound to c the whole time, with its own single cryptor.
    expect(a.media.boundTracks['TR_sfu_c_0'], 'acct_c/dev_c:0');
    expect(a.provider.keys['rx:TR_sfu_c_0@3'],
        a.provider.keys['acct_c/dev_c:0@3']);
    await end([a, b2, c]);
  });

  test('a receiver cryptor that will not enable unsubscribes the track',
      () async {
    final a = await start('a');
    a.sfu.failReceiverEnable = true;
    final b2 = await start('b');
    await admit(a, b2);
    expect(a.sfu.remote['TR_sfu_b_0']!.unsubscribed, isTrue);
    await end([a, b2]);
  });

  test('a remote track that cannot be muted is dropped, never played',
      () async {
    final a = await start('a');
    final b2 = await start('b');
    await admit(a, b2);
    final stuck = FakeRemoteTrack('TR_stuck', 'sfu_b')..refusesMute = true;
    a.sfu.emit(SfuTrackSubscribed(stuck));
    await a.settle();
    expect(stuck.unsubscribed, isTrue);
    expect(a.sfu.receiverFor('TR_stuck'), isNull);
    expect(a.media.boundTracks.containsKey('TR_stuck'), isFalse);
    await end([a, b2]);
  });

  test('mute keeps the capture disabled, and unmute opens it again', () async {
    final a = await start('a');
    final track = a.sfu.published.single;
    await a.media.setMicMuted(true);
    expect(a.media.micMuted, isTrue);
    expect(track.enabled, isFalse);
    final b2 = await start('b');
    await admit(a, b2);
    expect(track.enabled, isFalse, reason: 'a key switch does not unmute');
    await a.media.setMicMuted(false);
    expect(track.enabled, isTrue);
    expect(a.media.canShareScreen, isFalse);
    await end([a, b2]);
  });

  group('RoomCallFactory', () {
    test('no fail-closed key provider: no call group is opened', () async {
      final source = _FakeSource(parent);
      final factory = RoomCallFactory(
        api: FakeApi(server, member('a')),
        crypto: source,
        selfAccountId: 'acct_a',
        selfDeviceId: 'dev_a',
        openKeys: () async =>
            throw const FrameEncryptionUnavailable('no frame cryptor'),
        connectSfu: (_) => FakeSfu(hub, 'sfu_a'),
        scheduler: clock,
      );
      await expectLater(
          factory.open('conv_1'), throwsA(isA<FrameEncryptionUnavailable>()));
      expect(source.opened, 0);
    });

    test('a parent roster change refreshes the call, and closeAll ends it',
        () async {
      final source = _FakeSource(parent);
      final roster = ChangeNotifier();
      final provider = FakeKeyProvider([]);
      final factory = RoomCallFactory(
        api: FakeApi(server, member('a')),
        crypto: source,
        selfAccountId: 'acct_a',
        selfDeviceId: 'dev_a',
        rosterChanges: roster,
        openKeys: () => WebRtcFrameKeys.open(create: (_) async => provider),
        connectSfu: (_) => FakeSfu(hub, 'sfu_a'),
        scheduler: clock,
      );
      final call = await factory.open('conv_1');
      await call.engine.join('conv_1');
      await pump();
      expect(call.engine.phase, RoomPhase.active);
      final b2 = await start('b');
      await pump();
      // A change that is not to the parent's members does nothing.
      roster.notifyListeners();
      await pump();
      await clock.advance(const Duration(milliseconds: 250));
      expect(server.epoch, 0, reason: 'no refresh ran (the poll is 2 s)');
      parent.list.add(member('d'));
      roster.notifyListeners();
      await pump();
      await clock.advance(const Duration(milliseconds: 250));
      await b2.settle();
      expect(server.epoch, 1, reason: 'the roster change ran a refresh');
      expect(factory.openCalls, 1);
      await factory.closeAll();
      expect(factory.openCalls, 0);
      expect(source.handles.single.closed, isTrue);
      expect(provider.disposed, isTrue);
      expect(call.engine.phase, RoomPhase.left);
      await expectLater(factory.open('conv_1'), throwsStateError);
      await end([b2]);
    });
  });
}

class _FakeHandle implements CallGroupHandle {
  _FakeHandle(this.crypto);
  @override
  final CallGroupCrypto crypto;
  bool closed = false;
  @override
  void close() => closed = true;
}

class _FakeSource implements RoomCryptoSource {
  _FakeSource(this.parentGroups);
  @override
  final ParentGroupView parentGroups;
  int opened = 0;
  final List<_FakeHandle> handles = [];
  @override
  Future<CallGroupHandle> openCallGroup() async {
    opened++;
    final handle = _FakeHandle(FakeCrypto(member('a')));
    handles.add(handle);
    return handle;
  }
}
