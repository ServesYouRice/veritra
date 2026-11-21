part of 'app_state.dart';

/// C3 private channel membership in the app (docs/crypto.md, "C3 private
/// channel membership"; the rule is in
/// `core/roles/private_channel_membership.dart`, applied by the crypto
/// service).
///
/// The server's member list of a private channel only proposes. This part
/// pins every private channel's group this device sees, so a later server
/// label cannot switch the rule off, records the accounts this device's user
/// picks, and keeps every other server-proposed new account out of the adds
/// it discovers, before a key package is claimed for it.
extension PrivateChannelMembership on AppState {
  PrivateChannelAddGate? get _privateChannelGate {
    final Object crypto = cryptoService;
    return crypto is PrivateChannelAddGate ? crypto : null;
  }

  /// Whether [conversationId] is, or was once seen here as, a private
  /// channel's own group.
  Future<bool> _isPrivateChannelGroup(String conversationId) async =>
      privateGroupChannel(conversationId) != null ||
      await localStore.loadSetting(privateChannelPinSetting(conversationId)) ==
          '1';

  /// Pins [conversationId] as a private channel's own group on this device.
  Future<void> _pinPrivateChannelGroup(String conversationId) async {
    final key = privateChannelPinSetting(conversationId);
    if (await localStore.loadSetting(key) == '1') return;
    await localStore.saveSetting(key, '1');
  }

  /// Pins the group of every routed private channel the server listed.
  Future<void> _pinRoutedPrivateChannels() async {
    for (final channels in channelsByCommunity.values.toList()) {
      for (final channel in channels) {
        final conversationId = channel.conversationId;
        if (channel.kind != 'private' ||
            !channel.isRouted ||
            conversationId == null) {
          continue;
        }
        try {
          await _pinPrivateChannelGroup(conversationId);
        } catch (err) {
          // Retried on the next refresh; the label still holds meanwhile.
          developer.log(
            'c3_private_pin_failed ${err.runtimeType}',
            name: 'veritra.sync',
          );
        }
      }
    }
  }

  /// Records that this device's user picked [accountId] for the private
  /// channel [conversationId]: only then may this device add a new account
  /// there (and only while its account is an owner, admin or moderator
  /// under the verified record, judged when the add is staged).
  Future<void> _pickPrivateChannelMember(
    String conversationId,
    String accountId,
  ) async {
    final key = privateChannelPicksSetting(conversationId);
    final now = DateTime.now();
    final picks = decodePrivateChannelPicks(
      await localStore.loadSetting(key),
      now,
    );
    picks[accountId] =
        now.add(privateChannelPickLifetime).millisecondsSinceEpoch;
    await localStore.saveSetting(key, encodePrivateChannelPicks(picks));
  }

  /// Takes back a pick whose add the server refused.
  Future<void> _unpickPrivateChannelMember(
    String conversationId,
    String accountId,
  ) async {
    final key = privateChannelPicksSetting(conversationId);
    final picks = decodePrivateChannelPicks(
      await localStore.loadSetting(key),
      DateTime.now(),
    );
    if (picks.remove(accountId) == null) return;
    await localStore.saveSetting(key, encodePrivateChannelPicks(picks));
  }

  /// [refs] without the devices of accounts this device may not add to
  /// [conversationId] (all of them unless it is a private channel's group).
  Future<List<MlsDeviceRef>> _privateChannelRefs(
    String conversationId,
    List<MlsDeviceRef> refs,
  ) async {
    final gate = _privateChannelGate;
    if (gate == null || refs.isEmpty) return refs;
    final allowed = await gate.privateChannelAddable(conversationId, {
      for (final ref in refs) ref.accountId,
    });
    return [
      for (final ref in refs)
        if (allowed.contains(ref.accountId)) ref,
    ];
  }
}
