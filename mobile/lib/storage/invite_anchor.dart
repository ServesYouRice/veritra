/// A group invitation anchor kept locally until the encrypted Welcome arrives.
/// No link secret or locator is retained or exported in backups.
class InviteAnchor {
  InviteAnchor(
      {required this.conversationId,
      required this.accountId,
      required this.deviceId,
      required List<int> signingKey})
      : signingKey = List<int>.unmodifiable(signingKey) {
    if (conversationId.isEmpty ||
        accountId.isEmpty ||
        deviceId.isEmpty ||
        signingKey.length != 32)
      throw ArgumentError('invalid invitation anchor');
  }
  final String conversationId;
  final String accountId;
  final String deviceId;
  final List<int> signingKey;
}
