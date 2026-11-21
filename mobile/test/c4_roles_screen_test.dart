import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/governance_commands.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/features/chat/roles_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

/// C4 roles screen (docs/designs/C4-custom-roles.md): the owner is asked to
/// mark the admins it trusts as electors, and a handover this device's own
/// clocks would have refused (D81) is shown as a warning. Also the read API
/// other packages use (`AppState.verifiedRoleOf`).
void main() {
  const group = 'conv_g';

  Future<AppState> fixture(
    GovernanceState record,
    String self, {
    GovernanceObservations? observed,
    String kind = 'group',
    _RoleCrypto? crypto,
  }) async {
    final state = AppState(
      apiClientFactory: (_) => ApiClient(baseUrl: 'https://example.test'),
      syncServiceFactory: (_, __) => _QuietSync(),
      localStore: MemoryLocalStore(),
      cryptoService: crypto ?? _RoleCrypto(record, observed),
    );
    state.session = Session(
      baseUrl: 'https://example.test',
      token: 'token',
      accountId: self,
      deviceId: 'dev_$self',
    );
    if (crypto != null) {
      state.api = ApiClient(baseUrl: 'https://example.test');
    }
    state.conversations = [
      Conversation(id: group, kind: kind, title: 'Group'),
    ];
    return state;
  }

  Future<void> pump(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RolesScreen(state: state, conversationId: group),
      ),
    );
    await tester.pumpAndSettle();
  }

  final l10n = englishL10n;

  testWidgets('the owner is asked to mark trusted admins as electors', (
    tester,
  ) async {
    final record = GovernanceState(
      rev: 3,
      owner: 'alice',
      ownerRev: 3,
      admins: const {'bob': 2, 'carol': 3},
      electors: const {'bob'},
      joined: const {'alice': 0, 'bob': 1, 'carol': 1},
    );
    await pump(tester, await fixture(record, 'alice'));
    expect(find.text(l10n.rolesElectorHint), findsOneWidget);
    expect(find.text(l10n.rolesEarlyWin), findsNothing);
  });

  testWidgets('no elector prompt once every admin is an elector', (
    tester,
  ) async {
    final record = GovernanceState(
      rev: 3,
      owner: 'alice',
      ownerRev: 3,
      admins: const {'bob': 2},
      electors: const {'bob'},
      joined: const {'alice': 0, 'bob': 1, 'carol': 1},
    );
    await pump(tester, await fixture(record, 'alice'));
    expect(find.text(l10n.rolesElectorHint), findsNothing);
  });

  testWidgets('a non-owner is never shown the elector prompt', (tester) async {
    final record = GovernanceState(
      rev: 3,
      owner: 'alice',
      ownerRev: 3,
      admins: const {'bob': 2, 'carol': 3},
      joined: const {'alice': 0, 'bob': 1, 'carol': 1},
    );
    await pump(tester, await fixture(record, 'bob'));
    expect(find.text(l10n.rolesElectorHint), findsNothing);
  });

  testWidgets(
    'an early handover warns while it is the owner\'s last decision',
    (tester) async {
      final won = GovernanceState(
        rev: 6,
        ownerRev: 6,
        owner: 'bob',
        admins: const {'alice': 6},
        joined: const {'alice': 0, 'bob': 1, 'carol': 1},
      );
      final state = await fixture(won, 'carol');
      await state.localStore.saveSetting(governanceEarlyWinSetting(group), '6');
      await pump(tester, state);
      expect(find.text(l10n.rolesEarlyWin), findsOneWidget);

      // The new owner's next decision moves ownerRev: the warning ends.
      final later = await fixture(
        won.copyWith(rev: 7, ownerRev: 7, moderators: {'carol'}),
        'carol',
      );
      await later.localStore.saveSetting(governanceEarlyWinSetting(group), '6');
      await tester.pumpWidget(const SizedBox());
      await pump(tester, later);
      expect(find.text(l10n.rolesEarlyWin), findsNothing);
    },
  );

  testWidgets('an election is offered only to who may open one', (
    tester,
  ) async {
    final record = GovernanceState(
      rev: 3,
      owner: 'alice',
      ownerRev: 3,
      admins: const {'bob': 2, 'carol': 3},
      electors: const {'bob'},
      joined: const {'alice': 0, 'bob': 1, 'carol': 1},
    );
    GovernanceObservations quiet(Duration since) => GovernanceObservations(
          owner: 'alice',
          ownerRev: 3,
          lastOwnerActivity: DateTime.now().toUtc().subtract(since),
        );
    // Bob is the elector and the owner has been away 31 days here.
    await pump(
      tester,
      await fixture(record, 'bob', observed: quiet(const Duration(days: 31))),
    );
    expect(find.text(l10n.rolesStartElection), findsOneWidget);
    // Not yet 30 days on this device's clock.
    await tester.pumpWidget(const SizedBox());
    await pump(
      tester,
      await fixture(record, 'bob', observed: quiet(const Duration(days: 29))),
    );
    expect(find.text(l10n.rolesStartElection), findsNothing);
    // Carol is an admin but not an elector, while an elector is present.
    await tester.pumpWidget(const SizedBox());
    await pump(
      tester,
      await fixture(
        record,
        'carol',
        observed: quiet(const Duration(days: 31)),
      ),
    );
    expect(find.text(l10n.rolesStartElection), findsNothing);
  });

  test('verifiedRoleOf reads only the verified record', () async {
    final record = GovernanceState(
      rev: 2,
      owner: 'alice',
      ownerRev: 2,
      admins: const {'bob': 1},
      moderators: const {'carol'},
      joined: const {'alice': 0, 'bob': 1, 'carol': 1, 'dave': 2},
    );
    final state = await fixture(record, 'alice');
    expect(state.verifiedRoleOf(group, 'alice'), BuiltInRole.owner);
    expect(state.verifiedRoleOf(group, 'bob'), BuiltInRole.admin);
    expect(state.verifiedRoleOf(group, 'carol'), BuiltInRole.moderator);
    expect(state.verifiedRoleOf(group, 'dave'), BuiltInRole.member);
    // No record (a DM, a group from before C4): no verified role, even
    // though the server's word would name one.
    state.conversations = [
      ...state.conversations,
      Conversation(
        id: 'conv_dm',
        kind: 'dm',
        title: 'DM',
        createdBy: 'alice',
      ),
    ];
    expect(state.verifiedRoleOf('conv_dm', 'alice'), isNull);
    expect(state.roleOf('conv_dm', 'alice'), 'owner');
  });

  // C4 record format 3: the group rules section.
  GovernanceState rules({bool pins = false, bool info = false}) =>
      GovernanceState(
        rev: 3,
        owner: 'alice',
        ownerRev: 1,
        admins: const {'bob': 1},
        joined: const {'alice': 0, 'bob': 1, 'carol': 2},
        adminsOnlyPins: pins,
        channelInfoRestricted: info,
      );

  SwitchListTile switchFor(WidgetTester tester, String key) =>
      tester.widget<SwitchListTile>(find.byKey(Key(key)));

  /// The rules section is the last one: a tall window shows it all.
  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('a group admin switches pins to admins only', (tester) async {
    tall(tester);
    final crypto = _RoleCrypto(rules(), null, actor: 'bob');
    await pump(tester, await fixture(rules(), 'bob', crypto: crypto));
    expect(find.text(l10n.rolesRulesSection.toUpperCase()), findsOneWidget);
    expect(find.text(l10n.rolesPinsAdminsOnlyDetail), findsOneWidget);
    expect(find.byKey(const Key('rules-channel-info')), findsNothing);
    final pins = switchFor(tester, 'rules-admin-pins');
    expect(pins.value, isFalse);
    expect(pins.onChanged, isNotNull);
    expect(find.text(l10n.rolesRulesAdminsOnly), findsNothing);
    await tester.tap(find.byKey(const Key('rules-admin-pins')));
    await tester.pumpAndSettle();
    expect(crypto.staged.single.adminsOnlyPins, isTrue);
    expect(crypto.staged.single.rev, 4);
  });

  testWidgets('a member sees the rules but cannot switch them', (
    tester,
  ) async {
    tall(tester);
    await pump(tester, await fixture(rules(pins: true), 'carol'));
    final pins = switchFor(tester, 'rules-admin-pins');
    expect(pins.value, isTrue);
    expect(pins.onChanged, isNull);
    expect(find.text(l10n.rolesRulesAdminsOnly), findsOneWidget);
  });

  testWidgets('a community gets the channel-info switch instead', (
    tester,
  ) async {
    tall(tester);
    final crypto = _RoleCrypto(rules(), null, actor: 'alice');
    await pump(
      tester,
      await fixture(
        rules(),
        'alice',
        kind: 'community_shared',
        crypto: crypto,
      ),
    );
    expect(find.byKey(const Key('rules-admin-pins')), findsNothing);
    expect(find.text(l10n.rolesChannelInfoRestrictedDetail), findsOneWidget);
    final info = switchFor(tester, 'rules-channel-info');
    expect(info.value, isFalse);
    await tester.tap(find.byKey(const Key('rules-channel-info')));
    await tester.pumpAndSettle();
    expect(crypto.staged.single.channelInfoRestricted, isTrue);
    // The owner's switch is not a role decision (D86): ownerRev stays.
    expect(crypto.staged.single.ownerRev, 1);
  });
}

class _QuietSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}

/// Holds one record for [group]; every other MLS call is unused here.
class _RoleCrypto extends UnavailableCryptoService
    implements MlsConversationCryptoService, RoleCommandCryptoService {
  _RoleCrypto(this.record, this.observed, {this.actor});
  final GovernanceState record;
  final GovernanceObservations? observed;

  /// When set, each staged role change is built as this account and kept.
  final String? actor;
  final List<GovernanceState> staged = <GovernanceState>[];

  @override
  GovernanceState? governanceOf(String conversationId) =>
      conversationId == 'conv_g' ? record : null;

  @override
  Future<GovernanceView?> governanceView(String groupId) async =>
      groupId == 'conv_g'
          ? GovernanceView(
              record: record,
              roster: record.joined.keys.toSet(),
              observations: observed,
            )
          : null;

  @override
  Future<void> stageRoleChange(
    String groupId,
    GovernanceState Function(
      GovernanceCommands commands,
      GovernanceObservations? observed,
      DateTime now,
    ) build,
  ) async {
    final self = actor;
    if (self == null) return;
    staged.add(
      build(
        GovernanceCommands(
          state: record,
          actor: self,
          members: record.joined.keys.toSet(),
        ),
        observed,
        DateTime.now().toUtc(),
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}
