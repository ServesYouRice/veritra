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

  GovernanceObservations reduce(GovernanceObservations? previous) =>
      previous == null
          ? GovernanceObservations.firstSeen(state, receivedAt.toUtc())
          : previous.accepted(state, receivedAt.toUtc(),
              ownerActive: authenticatedSender == state.owner);
}
