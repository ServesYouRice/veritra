// C4: canonical bytes of a group's role record (format version 2).
//
// Pure Dart, no ABI. The bytes are what a GroupContext extension would carry
// (docs/crypto.md, "Group role state (C4)"); Rust treats them as opaque and
// Dart judges them with `validateCommit`. Decoding is strict: one accepted
// byte string per state, anything else is refused and never guessed at, so two
// honest devices cannot hold different states for the same extension bytes.
import 'dart:convert';
import 'dart:typed_data';

import 'governance.dart';

/// The only version this app reads. Version 1 (admins, moderators and posting
/// only) was documented but never written by any build, so it is withdrawn.
const int governanceRecordVersion = 2;

/// Longest accepted record. Counts are u16 and ids up to 255 bytes, so an
/// unbounded record could be huge; no honest group comes near this.
const int maxGovernanceRecordBytes = 256 * 1024;

/// An id (account or channel) is 1 to 255 bytes of UTF-8.
const int maxGovernanceIdBytes = 255;

class GovernanceCodecException implements Exception {
  const GovernanceCodecException(this.message);
  final String message;
  @override
  String toString() => 'GovernanceCodecException: $message';
}

const int _flagAdminsOnlyPosting = 1;
const int _flagElection = 2;

/// C5: the record carries timeouts (docs/crypto.md, "C5 timeouts in the
/// record"). A record without any is byte for byte what it was before, so
/// existing groups and vectors are unchanged; a build older than this
/// refuses a record with timeouts (unknown flag bit), and its sync stops.
const int _flagTimeouts = 4;
const int _knownFlags = _flagAdminsOnlyPosting | _flagElection | _flagTimeouts;
const int _adminFlagElector = 1;

/// Encodes [state] canonically. Throws [GovernanceCodecException] when the
/// state could not be decoded back (an invariant the format needs is broken).
Uint8List encodeGovernance(GovernanceState state) {
  _checkShape(state);
  final w = _Writer();
  w.u8(governanceRecordVersion);
  w.u64(state.rev);
  w.u64(state.ownerRev);
  final election = state.election;
  w.u8((state.adminsOnlyPosting ? _flagAdminsOnlyPosting : 0) |
      (election != null ? _flagElection : 0) |
      (state.timeouts.isNotEmpty ? _flagTimeouts : 0));
  w.id(state.owner ?? '', allowEmpty: true);
  final admins = _sorted(state.admins.keys);
  w.u16(admins.length);
  for (final a in admins) {
    w.id(a);
    w.u64(state.admins[a]!);
    w.u8(state.electors.contains(a) ? _adminFlagElector : 0);
  }
  final moderators = _sorted(state.moderators);
  w.u16(moderators.length);
  for (final m in moderators) {
    w.id(m);
  }
  final channels = _sorted(state.announcementChannels);
  w.u16(channels.length);
  for (final c in channels) {
    w.id(c);
  }
  final joined = _sorted(state.joined.keys);
  w.u16(joined.length);
  for (final a in joined) {
    w.id(a);
    w.u64(state.joined[a]!);
  }
  if (election != null) {
    w.u64(election.opened);
    final electorate = _sorted(election.electorate);
    w.u16(electorate.length);
    for (final a in electorate) {
      w.id(a);
    }
    final voters = _sorted(election.votes.keys);
    w.u16(voters.length);
    for (final v in voters) {
      w.id(v);
      w.id(election.votes[v]!);
    }
  }
  if (state.timeouts.isNotEmpty) {
    final timedOut = _sorted(state.timeouts.keys);
    w.u16(timedOut.length);
    for (final a in timedOut) {
      final t = state.timeouts[a]!;
      w.id(a);
      w.u64(t.epoch);
      w.u64(t.fromMs);
      w.u64(t.untilMs);
    }
  }
  final out = w.bytes();
  if (out.length > maxGovernanceRecordBytes) {
    throw const GovernanceCodecException('record too large');
  }
  return out;
}

/// Decodes [bytes]. Throws [GovernanceCodecException] on anything that is not
/// exactly the canonical encoding of a well-formed state.
GovernanceState decodeGovernance(Uint8List bytes) {
  if (bytes.length > maxGovernanceRecordBytes) {
    throw const GovernanceCodecException('record too large');
  }
  final r = _Reader(bytes);
  final version = r.u8();
  if (version != governanceRecordVersion) {
    throw GovernanceCodecException('unknown version $version');
  }
  final rev = r.u64();
  final ownerRev = r.u64();
  final flags = r.u8();
  if (flags & ~_knownFlags != 0) {
    throw const GovernanceCodecException('unknown flag bits');
  }
  final ownerId = r.id(allowEmpty: true);
  final admins = <String, int>{};
  final electors = <String>{};
  String? previous;
  final adminCount = r.u16();
  for (var i = 0; i < adminCount; i++) {
    final account = r.id();
    previous = _ascending(previous, account);
    final since = r.u64();
    final adminFlags = r.u8();
    if (adminFlags & ~_adminFlagElector != 0) {
      throw const GovernanceCodecException('unknown admin flag bits');
    }
    admins[account] = since;
    if (adminFlags & _adminFlagElector != 0) electors.add(account);
  }
  final moderators = _readIdList(r, r.u16());
  final channelCount = r.u16();
  if (channelCount > maxAnnouncementChannels) {
    throw const GovernanceCodecException('too many channels');
  }
  final channels = _readIdList(r, channelCount);
  final joined = <String, int>{};
  previous = null;
  final joinedCount = r.u16();
  for (var i = 0; i < joinedCount; i++) {
    final account = r.id();
    previous = _ascending(previous, account);
    joined[account] = r.u64();
  }
  Election? election;
  if (flags & _flagElection != 0) {
    final opened = r.u64();
    final electorate = _readIdList(r, r.u16());
    final votes = <String, String>{};
    previous = null;
    final voteCount = r.u16();
    for (var i = 0; i < voteCount; i++) {
      final voter = r.id();
      previous = _ascending(previous, voter);
      votes[voter] = r.id();
    }
    election = Election(opened: opened, electorate: electorate, votes: votes);
  }
  final timeouts = <String, MemberTimeout>{};
  if (flags & _flagTimeouts != 0) {
    previous = null;
    final count = r.u16();
    // The flag means at least one: an empty list has one encoding, no flag.
    if (count == 0) throw const GovernanceCodecException('empty timeouts');
    for (var i = 0; i < count; i++) {
      final account = r.id();
      previous = _ascending(previous, account);
      timeouts[account] = MemberTimeout(
        epoch: r.u64(),
        fromMs: r.u64(),
        untilMs: r.u64(),
      );
    }
  }
  r.end();
  final state = GovernanceState(
    rev: rev,
    owner: ownerId.isEmpty ? null : ownerId,
    ownerRev: ownerRev,
    admins: admins,
    moderators: moderators,
    adminsOnlyPosting: flags & _flagAdminsOnlyPosting != 0,
    announcementChannels: channels,
    electors: electors,
    election: election,
    joined: joined,
    timeouts: timeouts,
  );
  _checkShape(state);
  return state;
}

/// Invariants the format relies on. The rules engine (`validateCommit`) judges
/// whether a *change* is allowed; this only rejects states that no sequence of
/// valid commits could produce.
void _checkShape(GovernanceState s) {
  void bad(String why) => throw GovernanceCodecException(why);
  if (s.rev < 0) bad('negative rev');
  if (s.ownerRev < 0 || s.ownerRev > s.rev) bad('owner_rev out of range');
  final owner = s.owner;
  if (owner != null) {
    if (s.admins.containsKey(owner) || s.moderators.contains(owner)) {
      bad('owner also in a role list');
    }
  }
  for (final a in s.admins.entries) {
    if (a.value < 0 || a.value > s.rev) bad('admin since out of range');
    if (s.moderators.contains(a.key)) bad('account is admin and moderator');
  }
  if (!s.admins.keys.toSet().containsAll(s.electors)) {
    bad('elector is not an admin');
  }
  if (s.announcementChannels.length > maxAnnouncementChannels) {
    bad('too many channels');
  }
  for (final j in s.joined.values) {
    if (j < 0 || j > s.rev) bad('joined out of range');
  }
  final e = s.election;
  if (e != null) {
    if (e.opened < 0 || e.opened > s.rev) bad('election opened out of range');
    if (e.electorate.isEmpty) bad('empty electorate');
    for (final v in e.votes.keys) {
      if (!e.electorate.contains(v)) bad('vote from outside the electorate');
    }
  }
  if (s.timeouts.length > 0xffff) bad('too many timeouts');
  for (final t in s.timeouts.values) {
    if (!t.wellFormed) bad('timeout out of range');
  }
  for (final id in [
    if (owner != null) owner,
    ...s.admins.keys,
    ...s.moderators,
    ...s.announcementChannels,
    ...s.electors,
    ...s.joined.keys,
    if (e != null) ...e.electorate,
    if (e != null) ...e.votes.keys,
    if (e != null) ...e.votes.values,
    ...s.timeouts.keys,
  ]) {
    _checkId(id);
  }
}

void _checkId(String id) {
  final bytes = utf8.encode(id);
  if (bytes.isEmpty || bytes.length > maxGovernanceIdBytes) {
    throw const GovernanceCodecException('id length');
  }
  // A lone surrogate encodes as U+FFFD and would not decode back to the same
  // string, so the committer and every receiver could hold different states.
  if (utf8.decode(bytes) != id) {
    throw const GovernanceCodecException('id is not valid Unicode');
  }
}

/// Sorts by UTF-8 bytes, the order the format uses. Dart's string order is by
/// UTF-16 code unit and differs for characters outside the BMP.
List<String> _sorted(Iterable<String> ids) {
  final list = [
    for (final id in ids) (id, Uint8List.fromList(utf8.encode(id))),
  ]..sort((a, b) => _compareBytes(a.$2, b.$2));
  return [for (final e in list) e.$1];
}

int _compareBytes(Uint8List a, Uint8List b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Accepts [next] only when it sorts strictly after [previous] by bytes.
String _ascending(String? previous, String next) {
  if (previous != null &&
      _compareBytes(Uint8List.fromList(utf8.encode(previous)),
              Uint8List.fromList(utf8.encode(next))) >=
          0) {
    throw const GovernanceCodecException('list not sorted or has duplicates');
  }
  return next;
}

Set<String> _readIdList(_Reader r, int count) {
  final out = <String>{};
  String? previous;
  for (var i = 0; i < count; i++) {
    final id = r.id();
    previous = _ascending(previous, id);
    out.add(id);
  }
  return out;
}

class _Writer {
  final BytesBuilder _b = BytesBuilder(copy: false);

  void u8(int v) => _b.addByte(v);

  void u16(int v) {
    if (v < 0 || v > 0xffff) {
      throw const GovernanceCodecException('count too large');
    }
    _b
      ..addByte(v >> 8)
      ..addByte(v & 0xff);
  }

  void u64(int v) {
    if (v < 0) throw const GovernanceCodecException('negative number');
    for (var shift = 56; shift >= 0; shift -= 8) {
      _b.addByte((v >> shift) & 0xff);
    }
  }

  void id(String id, {bool allowEmpty = false}) {
    final bytes = utf8.encode(id);
    if (bytes.isEmpty && allowEmpty) {
      u16(0);
      return;
    }
    if (bytes.isEmpty || bytes.length > maxGovernanceIdBytes) {
      throw const GovernanceCodecException('id length');
    }
    u16(bytes.length);
    _b.add(bytes);
  }

  Uint8List bytes() => _b.toBytes();
}

class _Reader {
  _Reader(this._bytes);
  final Uint8List _bytes;
  int _pos = 0;

  int u8() {
    if (_pos >= _bytes.length) {
      throw const GovernanceCodecException('truncated');
    }
    return _bytes[_pos++];
  }

  int u16() => (u8() << 8) | u8();

  int u64() {
    final high = u8();
    if (high & 0x80 != 0) {
      throw const GovernanceCodecException('number too large');
    }
    var v = high;
    for (var i = 0; i < 7; i++) {
      v = (v << 8) | u8();
    }
    return v;
  }

  String id({bool allowEmpty = false}) {
    final n = u16();
    if (n == 0 && allowEmpty) return '';
    if (n == 0 || n > maxGovernanceIdBytes) {
      throw const GovernanceCodecException('id length');
    }
    if (_pos + n > _bytes.length) {
      throw const GovernanceCodecException('truncated');
    }
    final slice = Uint8List.sublistView(_bytes, _pos, _pos + n);
    _pos += n;
    final String text;
    try {
      text = utf8.decode(slice);
    } on FormatException {
      throw const GovernanceCodecException('id is not UTF-8');
    }
    // utf8.decode drops a leading byte-order mark; the bytes must round-trip.
    if (!_sameBytes(utf8.encode(text), slice)) {
      throw const GovernanceCodecException('id is not canonical UTF-8');
    }
    return text;
  }

  void end() {
    if (_pos != _bytes.length) {
      throw const GovernanceCodecException('trailing bytes');
    }
  }
}
