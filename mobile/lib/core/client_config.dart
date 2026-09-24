import 'transport_policy.dart';

/// Build-level settings that differ between the release entry point
/// (`main.dart`) and the demo entry point (`main_demo.dart`, decision D11).
///
/// The default is the release configuration, so every existing caller and
/// test keeps release behaviour unless it opts in.
class ClientConfig {
  const ClientConfig({
    this.demo = false,
    this.transport = TransportPolicy.production,
    this.deviceName = 'Mobile device',
    this.defaultServerUrl,
  });

  static const ClientConfig production = ClientConfig();

  /// True only in demo builds, which run unreviewed crypto and must say so.
  final bool demo;

  /// Which server origins this build may use.
  final TransportPolicy transport;

  /// The name this device reports at enrollment.
  final String deviceName;

  /// Prefilled on the connect screen in demo builds. Never set in release.
  final String? defaultServerUrl;
}
