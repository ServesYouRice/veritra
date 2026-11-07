import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/membership_invite_link.dart';
import 'package:private_messenger/core/sha256.dart';

/// Secret 00 01 .. 1f, and the locator and link derived from it. The locator
/// is SHA-256 of "veritra/membership-invite/v1/locator\0" and the secret,
/// computed independently with Python's hashlib.
const _secretText = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';
const _locator =
    '4437d01b5bc6825b22a3de68051fee45b5809368049546cf0a8169cdb2ddcc52';
const _origin = 'https://chat.example.org';

void main() {
  group('sha256', () {
    test('matches the FIPS 180-4 vectors', () {
      expect(sha256Hex(const <int>[]),
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(sha256Hex(utf8.encode('abc')),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(
          sha256Hex(utf8.encode(
              'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq')),
          '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
      expect(sha256Hex(List<int>.filled(1000, 0x61)),
          '41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3');
    });

    test('pads at every block boundary', () {
      // 55 and 56 bytes straddle the single-block limit; 63 to 65 the block size.
      final seen = <String>{};
      for (final length in <int>[55, 56, 63, 64, 65, 119, 120]) {
        final digest = sha256Hex(List<int>.filled(length, 0x62));
        expect(digest, hasLength(64));
        seen.add(digest);
      }
      expect(seen, hasLength(7));
    });
  });

  group('MembershipInviteLink', () {
    MembershipInviteLink? parse(String text, {String origin = _origin}) =>
        MembershipInviteLink.tryParse(text, expectedOrigin: origin);

    test('derives the locator from the secret, not the secret itself', () {
      final link = parse('$_origin/join#v1.$_secretText')!;
      expect(link.locator, _locator);
      expect(link.locator, isNot(contains(_secretText)));
      expect(link.url, '$_origin/join#v1.$_secretText');
    });

    test('round-trips a generated link', () {
      final generated = MembershipInviteLink.generate(
          origin: 'HTTPS://Chat.Example.org:443', random: Random(7));
      expect(generated.origin, _origin);
      final parsed = parse(generated.url)!;
      expect(parsed.locator, generated.locator);
      expect(parsed.url, generated.url);
      expect(generated.locator, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('two generated links differ', () {
      final a = MembershipInviteLink.generate(origin: _origin);
      final b = MembershipInviteLink.generate(origin: _origin);
      expect(a.locator, isNot(b.locator));
    });

    test('keeps the secret after the # and out of everything else', () {
      final link = parse('$_origin/join#v1.$_secretText')!;
      final uri = Uri.parse(link.url);
      expect(uri.fragment, 'v1.$_secretText');
      expect(uri.path, '/join');
      expect(uri.hasQuery, isFalse);
      expect(uri.removeFragment().toString(), isNot(contains(_secretText)));
      expect(link.toString(), isNot(contains(_secretText)));
      expect(link.toString(), isNot(contains(_locator)));
    });

    test('accepts surrounding whitespace and an origin spelled differently',
        () {
      expect(parse('  $_origin/join#v1.$_secretText\n'), isNotNull);
      expect(parse('HTTPS://CHAT.example.org:443/join#v1.$_secretText'),
          isNotNull);
      expect(
          parse('http://127.0.0.1:8080/join#v1.$_secretText',
              origin: 'http://127.0.0.1:8080/'),
          isNotNull);
    });

    test('rejects another origin, scheme or port', () {
      for (final text in <String>[
        'https://evil.example.com/join#v1.$_secretText',
        'http://chat.example.org/join#v1.$_secretText',
        'https://chat.example.org:8443/join#v1.$_secretText',
        'https://chat.example.org.evil.test/join#v1.$_secretText',
        'https://user:pw@chat.example.org/join#v1.$_secretText',
      ]) {
        expect(parse(text), isNull, reason: text.split('#').first);
      }
    });

    test('rejects anything but exactly /join and a v1 fragment', () {
      for (final text in <String>[
        '',
        '   ',
        'not a link',
        '$_origin/join',
        '$_origin/join#',
        '$_origin/join#v1.',
        '$_origin/join#v2.$_secretText',
        '$_origin/join#$_secretText',
        '$_origin/join?x=1#v1.$_secretText',
        '$_origin/join/#v1.$_secretText',
        '$_origin/other#v1.$_secretText',
        '$_origin#v1.$_secretText',
        '$_origin/join#v1.${_secretText}A',
        '$_origin/join#v1.${_secretText.substring(1)}',
        '$_origin/join#v1.${_secretText.replaceFirst('A', '!')}',
        '/join#v1.$_secretText',
        'join#v1.$_secretText',
      ]) {
        expect(parse(text), isNull, reason: text.split('#').first);
      }
      // A non-canonical spelling of the same bytes (the last base64 digit
      // carries only two bits) is refused, so one secret has one link.
      expect(
          parse('$_origin/join#v1.${_secretText.substring(0, 42)}9'), isNull);
      expect(parse('$_origin/join#v1.$_secretText${'x' * 600}'), isNull);
    });

    test('does not accept a bad expected origin', () {
      expect(parse('$_origin/join#v1.$_secretText', origin: 'chat'), isNull);
    });
  });
}
