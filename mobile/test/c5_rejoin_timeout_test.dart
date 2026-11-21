import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/governance_commands.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/features/communities/membership_screens.dart';
import 'package:private_messenger/l10n/app_localizations.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'l1_test_lists.dart';
import 'native_test_env.dart';

// C5 rejoin gap (docs/designs/C5-moderation.md, "Timeouts after a rejoin"):
// a rejoin restores the server's timeout (migration 0095) but not the C4
// record's. Owners and admins see it on the member screen, lift it on the
// server, or write it into the record by an explicit action that commits
// only when the rejoiner is in the MLS roster, the record lets them act and
// the end is far enough ahead. Nothing commits on its own.

const _community = 'comm_1';
const _shared = 'conv_shared';
const _owner = 'acct_owner';
const _mod = 'acct_mod';
const _bob = 'acct_bob';
const _carol = 'acct_carol';

class _QuietSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://example.test');

  String myRole = 'owner';
  List<CommunityTimeout> timeouts = <CommunityTimeout>[];
  int timeoutReads = 0;
  final List<String> moderation = <String>[];

  @override
  Future<List<ConversationMember>> communityMembers(
    String token,
    String communityId,
  ) async =>
      <ConversationMember>[
        ConversationMember(accountId: _owner, role: myRole, username: 'me'),
        ConversationMember(accountId: _bob, role: 'member', username: 'bob'),
      ];

  @override
  Future<List<CommunityTimeout>> communityTimeouts(
    String token,
    String communityId,
  ) async {
    timeoutReads++;
    return List<CommunityTimeout>.of(timeouts);
  }

  @override
  Future<DateTime?> setMemberTimeout(
    String token,
    String communityId,
    String accountId,
    int seconds,
  ) async {
    moderation.add('timeout:$communityId:$accountId:$seconds');
    if (seconds == 0) {
      timeouts = timeouts.where((t) => t.accountId != accountId).toList();
    }
    return null;
  }
}

/// A native service whose shared-group record and roster are fakes; a role
/// commit applies at once, as the real one does after the commit lands.
class _Roles extends TestNativeCryptoService {
  _Roles({required super.bindings, required super.localStore});

  String actor = _owner;
  GovernanceState record = GovernanceState(
    rev: 4,
    owner: _owner,
    ownerRev: 1,
    moderators: const {_mod},
    joined: const {_owner: 0, _mod: 1, _bob: 2, _carol: 3},
  );
  Set<String> roster = {_owner, _mod, _bob, _carol};
  int staged = 0;
  final List<String> refusals = <String>[];

  @override
  GovernanceState? governanceOf(String conversationId) =>
      conversationId == _shared ? record : null;

  @override
  Future<GovernanceView?> governanceView(String groupId) async =>
      groupId == _shared
          ? GovernanceView(record: record, roster: roster, observations: null)
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
    staged++;
    try {
      record = build(
        GovernanceCommands(
          state: record,
          actor: actor,
          members: roster,
          epoch: 9,
        ),
        null,
        DateTime.now().toUtc(),
      );
    } on GovernanceCommandException catch (err) {
      refusals.add(err.reason);
      rethrow;
    }
  }
}

CommunityTimeout _timeout(String account,
        {bool member = true, Duration? in_}) =>
    CommunityTimeout(
      accountId: account,
      username: null,
      timeoutUntil: DateTime.now().toUtc().add(in_ ?? const Duration(hours: 1)),
      member: member,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skip = nativeCryptoSkip();

  (AppState, _Roles, _Api) app() {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final store = MemoryLocalStore();
    final crypto = _Roles(bindings: bindings, localStore: store);
    final api = _Api();
    final state = AppState(
      apiClientFactory: (_) => api,
      syncServiceFactory: (_, __) => _QuietSync(),
      localStore: store,
      cryptoService: crypto,
    );
    addTearDown(state.dispose);
    state
      ..session = const Session(
        baseUrl: 'https://example.test',
        token: 'token',
        accountId: _owner,
        deviceId: 'dev_owner',
      )
      ..api = api
      ..conversations = [
        Conversation(id: _shared, kind: 'community_shared'),
      ]
      ..communities = [
        Community(id: _community, name: '', sharedConversationId: _shared),
      ];
    return (state, crypto, api);
  }

  group('app state', () {
    test(
      'offers only members with a gap the record lets this account fill',
      () async {
        final (state, crypto, _) = app();
        final offered = await state.serverTimeoutsToApply(_community, [
          _timeout(_bob),
          // Left: the Moderation screen's, never written to a record.
          _timeout(_carol, member: false),
          // The owner outranks a moderator too.
          _timeout(_mod),
        ]);
        expect(offered, {_bob, _mod});

        crypto.roster = {_owner, _mod, _carol};
        expect(
          await state.serverTimeoutsToApply(_community, [_timeout(_bob)]),
          isEmpty,
          reason: 'not in the MLS roster yet',
        );

        crypto
          ..roster = {_owner, _mod, _bob, _carol}
          ..actor = _mod;
        state.session = const Session(
          baseUrl: 'https://example.test',
          token: 'token',
          accountId: _mod,
          deviceId: 'dev_mod',
        );
        expect(
          await state.serverTimeoutsToApply(_community, [_timeout(_owner)]),
          isEmpty,
          reason: 'the record does not let a moderator act on the owner',
        );
        expect(crypto.staged, 0, reason: 'reading never commits');
      },
      skip: skip,
    );

    test(
      'applying commits the server end from now and never calls the server',
      () async {
        final (state, crypto, api) = app();
        final until = DateTime.now().toUtc().add(const Duration(hours: 2));
        final before = DateTime.now().millisecondsSinceEpoch;
        expect(
          await state.applyServerTimeoutToRecord(_community, _bob, until),
          isTrue,
        );
        final entry = crypto.record.timeouts[_bob]!;
        expect(entry.untilMs, until.millisecondsSinceEpoch);
        expect(entry.fromMs, greaterThanOrEqualTo(before));
        expect(entry.epoch, 9);
        expect(api.moderation, isEmpty);

        // A second admin's tap after the first landed changes nothing.
        expect(
          await state.applyServerTimeoutToRecord(_community, _bob, until),
          isFalse,
        );
        expect(crypto.refusals, ['no_change']);
        expect(crypto.record.timeouts[_bob], entry);
        expect(state.errorFor(Ops.members), isNotNull);
      },
      skip: skip,
    );

    test(
      'applying is refused for an end too close, or a rejoiner not in MLS',
      () async {
        final (state, crypto, _) = app();
        expect(
          await state.applyServerTimeoutToRecord(
            _community,
            _bob,
            DateTime.now().toUtc().add(const Duration(minutes: 4)),
          ),
          isFalse,
        );
        crypto.roster = {_owner, _mod, _carol};
        expect(
          await state.applyServerTimeoutToRecord(
            _community,
            _bob,
            DateTime.now().toUtc().add(const Duration(hours: 1)),
          ),
          isFalse,
        );
        expect(crypto.refusals, ['timeout_ending', 'not_member']);
        expect(crypto.record.timeouts, isEmpty);
      },
      skip: skip,
    );
  });

  group('member screen', () {
    Widget screen(AppState state) => MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CommunityDetailsScreen(
            key: UniqueKey(),
            state: state,
            community: Community(
              id: _community,
              name: 'Club',
              sharedConversationId: _shared,
            ),
          ),
        );

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Moderate @bob'));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'an owner sees the server-only timeout and applies it to the record',
      (tester) async {
        final (state, crypto, api) = app();
        api.timeouts = [_timeout(_bob)];
        await tester.pumpWidget(screen(state));
        await tester.pumpAndSettle();
        expect(find.textContaining('(server only)'), findsOneWidget);

        await openMenu(tester);
        expect(find.text('Lift timeout'), findsOneWidget);
        await tester.tap(find.text('Apply to the record'));
        await tester.pumpAndSettle();
        expect(crypto.staged, 1);
        expect(crypto.record.timeouts[_bob]?.untilMs,
            api.timeouts.single.timeoutUntil.millisecondsSinceEpoch);
        expect(find.text('Timeout added to the record.'), findsOneWidget);
        expect(api.moderation, isEmpty);
        // Now the record shows it: no "(server only)", no second Apply.
        expect(find.textContaining('(server only)'), findsNothing);
        expect(find.textContaining('Timed out until'), findsOneWidget);
        await openMenu(tester);
        expect(find.text('Apply to the record'), findsNothing);
        expect(find.text('Lift timeout'), findsOneWidget);
      },
      skip: skip != false,
    );

    testWidgets(
      'Lift clears the server-only timeout on the server, without a commit',
      (tester) async {
        final (state, crypto, api) = app();
        api.timeouts = [_timeout(_bob)];
        await tester.pumpWidget(screen(state));
        await tester.pumpAndSettle();
        await openMenu(tester);
        await tester.tap(find.text('Lift timeout'));
        await tester.pumpAndSettle();
        expect(api.moderation, ['timeout:$_community:$_bob:0']);
        expect(crypto.staged, 0);
        expect(find.textContaining('(server only)'), findsNothing);
      },
      skip: skip != false,
    );

    testWidgets(
      'no Apply before the rejoiner is in MLS, or when the end is near',
      (tester) async {
        final (state, crypto, api) = app();
        crypto.roster = {_owner, _mod, _carol};
        api.timeouts = [_timeout(_bob)];
        await tester.pumpWidget(screen(state));
        await tester.pumpAndSettle();
        expect(find.textContaining('(server only)'), findsOneWidget);
        await openMenu(tester);
        expect(find.text('Lift timeout'), findsOneWidget);
        expect(find.text('Apply to the record'), findsNothing);
        await tester.tapAt(Offset.zero);
        await tester.pumpAndSettle();

        final (state2, crypto2, api2) = app();
        api2.timeouts = [_timeout(_bob, in_: const Duration(minutes: 3))];
        await tester.pumpWidget(screen(state2));
        await tester.pumpAndSettle();
        expect(api2.timeoutReads, 1);
        expect(find.textContaining('(server only)'), findsOneWidget);
        await openMenu(tester);
        expect(find.text('Apply to the record'), findsNothing);
        expect(crypto2.staged, 0);
      },
      skip: skip != false,
    );

    testWidgets(
      'a departed account\'s row and a moderator\'s screen show no gap',
      (tester) async {
        final (state, _, api) = app();
        // Bob is a member, but the server lists him as departed (a stale
        // list): no member row claims it.
        api.timeouts = [_timeout(_bob, member: false)];
        await tester.pumpWidget(screen(state));
        await tester.pumpAndSettle();
        expect(find.textContaining('(server only)'), findsNothing);

        final (modState, _, modApi) = app();
        modApi
          ..myRole = 'moderator'
          ..timeouts = [_timeout(_bob)];
        await tester.pumpWidget(screen(modState));
        await tester.pumpAndSettle();
        expect(find.text('@bob'), findsOneWidget, reason: 'the list loaded');
        expect(modApi.timeoutReads, 0, reason: 'the route is admins only');
        expect(find.textContaining('(server only)'), findsNothing);
      },
      skip: skip != false,
    );
  });
}
