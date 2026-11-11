import '../core/roles/governance.dart';
import '../core/roles/governance_codec.dart';
import '../core/roles/governance_commands.dart';

export '../core/roles/governance_commands.dart' show GovernanceObservations;

/// An observation of an accepted MLS transition, not server metadata.
/// [groupId] identifies the shared MLS group for community channels.
/// Construct only after checking the MLS sender and governance transition.
/// [receivedAt] is the local receipt time, never an envelope timestamp.
class GovernanceObservationChange {
  GovernanceObservationChange({
    required this.groupId,
    required this.state,
    required this.authenticatedSender,
    required this.receivedAt,
    this.senderApproved = true,
  }) {
    if (groupId.isEmpty ||
        groupId.length > 128 ||
        authenticatedSender.isEmpty ||
        authenticatedSender.length > 128) {
      throw const FormatException('invalid governance observation binding');
    }
    // Bound all record fields before either store mutates anything.
    encodeGovernance(state);
  }

  final String groupId;
  final GovernanceState state;
  final String authenticatedSender;
  final DateTime receivedAt;

  /// Whether the sender's leaf is on its account's L1 approved-device list.
  /// A leaf that is not never counts as the owner's activity: any member can
  /// add a leaf under the owner's account id (ABI 20 review note).
  final bool senderApproved;

  GovernanceObservations reduce(GovernanceObservations? previous) => previous ==
          null
      ? GovernanceObservations.firstSeen(state, receivedAt.toUtc())
      : previous.accepted(state, receivedAt.toUtc(),
          ownerActive: senderApproved && authenticatedSender == state.owner);
}
