// U21: the account invitation link `<origin>/invite#v1.<code>`
// (docs/designs/U21-account-invite-link.md).
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/account_invite_link.dart';
import 'package:private_messenger/core/membership_invite_link.dart';
import 'package:private_messenger/core/transport_policy.dart';

void main() {
  // The shape `domain.NewInviteCode` issues: unpadded base32, 26 characters.
  const code = 'MFRGGZDFMZTWQ2LKNNWG23TPOA';
  const origin = 'https://chat.example.org';
  const production = TransportPolicy.production;

  AccountInviteLink? parse(String text,
          {TransportPolicy transport = production}) =>
      AccountInviteLink.tryParse(text, transport: transport);

  test('builds and reads back the same server and code', () {
    final link = AccountInviteLink.forInvite(origin: '$origin/', code: code)!;
    expect(link.url, '$origin/invite#v1.$code');
    final read = parse(link.url)!;
    expect(read.origin, origin);
    expect(read.code, code);
  });

  test('canonicalises the origin and keeps the code as issued', () {
    final read = parse('  HTTPS://Chat.Example.org:443/invite#v1.$code\n')!;
    expect(read.origin, origin);
    expect(read.code, code);
    expect(parse('https://chat.example.org:8443/invite#v1.$code')!.origin,
        'https://chat.example.org:8443');
    // The server compares codes exactly: case is not folded.
    expect(parse('$origin/invite#v1.${code.toLowerCase()}')!.code,
        code.toLowerCase());
  });

  test('plain HTTP only to loopback, and only in demo builds', () {
    const loopback = 'http://127.0.0.1:8080/invite#v1.$code';
    expect(parse(loopback), isNull);
    expect(parse(loopback, transport: TransportPolicy.demo)!.origin,
        'http://127.0.0.1:8080');
    expect(
        parse('http://chat.example.org/invite#v1.$code',
            transport: TransportPolicy.demo),
        isNull);
  });

  test('refuses everything that is not exactly an invitation link', () {
    for (final text in <String>[
      '',
      code,
      'v1.$code',
      '/invite#v1.$code',
      '$origin/invite',
      '$origin/invite#',
      '$origin/invite#v1.',
      '$origin/invite#$code',
      '$origin/invite#v2.$code',
      '$origin/invite/#v1.$code',
      '$origin/invites#v1.$code',
      '$origin/join#v1.$code',
      '$origin/invite?x=1#v1.$code',
      'https://user:pw@chat.example.org/invite#v1.$code',
      'ftp://chat.example.org/invite#v1.$code',
      'veritra://invite#v1.$code',
      '$origin/invite#v1.short',
      '$origin/invite#v1.${'A' * 129}',
      '$origin/invite#v1.$code%41',
      '$origin/invit%65#v1.$code',
      '$origin/invite#v1.$code.extra',
      '$origin/invite#v1.MFRGGZDF MZTWQ2LK',
      '$origin/invite#v1.${'A' * 600}',
    ]) {
      expect(parse(text), isNull, reason: text);
    }
  });

  test(
      'a C1 group link is not an account invitation, and the other way '
      'round', () {
    final secret = 'A' * 43;
    final commitment = 'B' * 22;
    expect(parse('$origin/join#v2.$secret.$commitment'), isNull);
    expect(
        MembershipInviteLink.tryParse('$origin/invite#v1.$code',
            expectedOrigin: origin),
        isNull);
  });

  test('a code that cannot travel in a link gets no link', () {
    expect(AccountInviteLink.forInvite(origin: origin, code: 'ab cd'), isNull);
    expect(AccountInviteLink.forInvite(origin: origin, code: 'short'), isNull);
    expect(
        AccountInviteLink.forInvite(origin: 'not a url', code: code), isNull);
  });

  test('never prints the code', () {
    final link = parse('$origin/invite#v1.$code')!;
    expect(link.toString(), isNot(contains(code)));
  });
}
