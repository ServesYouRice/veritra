import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/section_header.dart';
import '../../ui/widgets/veritra_mark.dart';
import 'qr_scan_screen.dart';

enum AuthMode { owner, signIn, join, linkDevice }

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({required this.state, super.key});

  final AppState state;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final formKey = GlobalKey<FormState>();
  final url = TextEditingController(text: 'http://localhost:8080');
  final username = TextEditingController();
  final password = TextEditingController();
  final passwordConfirmation = TextEditingController();
  final setupToken = TextEditingController();
  final inviteCode = TextEditingController();
  final linkCode = TextEditingController();
  // Signing in (or joining) is the common case; "Owner" only applies to the
  // very first user of a fresh instance, so the setup probe below promotes
  // it when the server reports that setup is still required.
  AuthMode mode = AuthMode.signIn;
  bool showPassword = false;
  // null = unknown (instance not probed / unreachable).
  bool? setupRequired;
  Timer? _setupProbeDebounce;
  int _setupProbeGeneration = 0;

  @override
  void initState() {
    super.initState();
    url.addListener(_scheduleSetupProbe);
    _probeSetupStatus();
  }

  @override
  void dispose() {
    _setupProbeDebounce?.cancel();
    url.dispose();
    username.dispose();
    password.dispose();
    passwordConfirmation.dispose();
    setupToken.dispose();
    inviteCode.dispose();
    linkCode.dispose();
    super.dispose();
  }

  void _scheduleSetupProbe() {
    _setupProbeDebounce?.cancel();
    _setupProbeDebounce =
        Timer(const Duration(milliseconds: 600), _probeSetupStatus);
  }

  Future<void> _probeSetupStatus() async {
    final target = url.text.trim();
    final generation = ++_setupProbeGeneration;
    final required =
        target.isEmpty ? null : await widget.state.checkSetupRequired(target);
    if (!mounted || generation != _setupProbeGeneration) {
      return;
    }
    setState(() {
      setupRequired = required;
      if (required == true) {
        mode = AuthMode.owner;
      } else if (required == false && mode == AuthMode.owner) {
        mode = AuthMode.signIn;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pendingLink = widget.state.pendingDeviceLinkClaim?.deviceLink;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Form(
              key: formKey,
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.all(BoneSpacing.xl),
                children: <Widget>[
                  const _BrandHeader(),
                  const SizedBox(height: BoneSpacing.xl + BoneSpacing.sm),
                  // One path, chosen by the probe rather than asked for. The
                  // four-way SegmentedButton this replaces read as a debug
                  // menu and was the first thing a new user saw
                  // (`docs/design.md` §5).
                  SectionHeader(
                    _modeTitle,
                    padding: const EdgeInsets.only(bottom: BoneSpacing.xs),
                  ),
                  Text(
                    _modeDescription,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: BoneSpacing.xl),
                  if (setupRequired == true) ...<Widget>[
                    const _Callout(
                      icon: Icons.rocket_launch_outlined,
                      title: 'Fresh instance detected',
                      message: 'No owner account exists yet — create it '
                          'below.',
                    ),
                    const SizedBox(height: BoneSpacing.lg),
                  ],
                  _Field(
                    label: 'Instance URL',
                    child: TextFormField(
                      controller: url,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      validator: _validateUrl,
                      decoration: const InputDecoration(
                        hintText: 'https://chat.example.org',
                        prefixIcon: Icon(Icons.dns_outlined),
                      ),
                    ),
                  ),
                  const SizedBox(height: BoneSpacing.lg),
                  if (mode == AuthMode.linkDevice)
                    ..._linkDeviceFields(theme, pendingLink)
                  else
                    ..._credentialFields(),
                  const SizedBox(height: BoneSpacing.xl),
                  SizedBox(
                    width: double.infinity,
                    child: mode == AuthMode.linkDevice && pendingLink != null
                        ? FilledButton.icon(
                            onPressed:
                                widget.state.busy ? null : _completeDeviceLink,
                            icon: const Icon(Icons.sync),
                            label: const Text('Check approval'),
                          )
                        : FilledButton.icon(
                            onPressed: widget.state.busy ? null : _submit,
                            icon: widget.state.busy
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(mode == AuthMode.linkDevice
                                    ? Icons.qr_code_2
                                    : Icons.login),
                            label: Text(_submitLabel),
                          ),
                  ),
                  if (widget.state.error != null) ...<Widget>[
                    const SizedBox(height: BoneSpacing.lg),
                    _ErrorCard(message: widget.state.error!),
                  ],
                  const SizedBox(height: BoneSpacing.sm),
                  Center(
                    child: TextButton(
                      onPressed: _showOtherWays,
                      child: const Text('Other ways to connect'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _linkDeviceFields(ThemeData theme, DeviceLink? pendingLink) {
    return <Widget>[
      _Field(
        label: 'Link code',
        child: TextFormField(
          controller: linkCode,
          autocorrect: false,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          validator: (value) => value == null || value.trim().isEmpty
              ? 'Enter the link code from your existing device.'
              : null,
          style: BoneType.mono,
          decoration: const InputDecoration(
            hintText: 'From Settings → Link device',
            prefixIcon: Icon(Icons.qr_code_2),
          ),
        ),
      ),
      const SizedBox(height: BoneSpacing.md),
      OutlinedButton.icon(
        onPressed: widget.state.busy ? null : _scanLinkCode,
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Scan QR code'),
      ),
      if (pendingLink != null) ...<Widget>[
        const SizedBox(height: BoneSpacing.lg),
        _Callout(
          icon: Icons.verified_outlined,
          title: 'Verification code',
          message: 'Confirm this code on your already-linked device, then '
              'check approval below.',
          child: SelectableText(
            pendingLink.verificationCode,
            style: BoneType.mono.copyWith(
              fontSize: 22,
              letterSpacing: 3,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
      ],
    ];
  }

  List<Widget> _credentialFields() {
    return <Widget>[
      if (mode == AuthMode.join) ...<Widget>[
        _Field(
          label: 'Invite code',
          child: TextFormField(
            controller: inviteCode,
            autocorrect: false,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            validator: (value) => value == null || value.trim().isEmpty
                ? 'Enter the invite code you received.'
                : null,
            style: BoneType.mono,
            decoration: const InputDecoration(
              hintText: 'From an admin on this instance',
              prefixIcon: Icon(Icons.card_giftcard_outlined),
            ),
          ),
        ),
        const SizedBox(height: BoneSpacing.lg),
      ],
      _Field(
        label: 'Username',
        child: TextFormField(
          controller: username,
          autocorrect: false,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          validator: (value) => value == null || value.trim().isEmpty
              ? 'Enter a username.'
              : null,
          decoration: const InputDecoration(
            hintText: 'Your name on this instance',
            prefixIcon: Icon(Icons.person_outline),
          ),
        ),
      ),
      const SizedBox(height: BoneSpacing.lg),
      _Field(
        label: 'Password',
        child: TextFormField(
          controller: password,
          obscureText: !showPassword,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          validator: _validatePassword,
          decoration: InputDecoration(
            hintText: _isRegistration ? 'At least 12 characters' : null,
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              tooltip: showPassword ? 'Hide password' : 'Show password',
              icon: Icon(showPassword
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined),
              onPressed: () => setState(() => showPassword = !showPassword),
            ),
          ),
        ),
      ),
      if (_isRegistration) ...<Widget>[
        const SizedBox(height: BoneSpacing.lg),
        _Field(
          label: 'Confirm password',
          child: TextFormField(
            controller: passwordConfirmation,
            obscureText: !showPassword,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            validator: (value) =>
                value == password.text ? null : 'Passwords do not match.',
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.lock_reset_outlined),
            ),
          ),
        ),
      ],
      if (mode == AuthMode.owner) ...<Widget>[
        const SizedBox(height: BoneSpacing.lg),
        _Field(
          label: 'Setup token',
          child: TextFormField(
            controller: setupToken,
            obscureText: true,
            autocorrect: false,
            decoration: const InputDecoration(
              hintText: 'Required unless connecting on loopback',
              prefixIcon: Icon(Icons.vpn_key_outlined),
            ),
          ),
        ),
      ],
    ];
  }

  /// The three paths that are not the probed one, behind a single link.
  ///
  /// The gating is the same as the old segmented button's `enabled` flags:
  /// a mode that can only fail against this instance is not offered.
  Future<void> _showOtherWays() async {
    final chosen = await showModalBottomSheet<AuthMode>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final available = <AuthMode>[
          if (setupRequired != false) AuthMode.owner,
          if (setupRequired != true) AuthMode.signIn,
          if (setupRequired != true) AuthMode.join,
          if (setupRequired != true) AuthMode.linkDevice,
        ]..remove(mode);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: BoneSpacing.xl),
                child: SectionHeader('Other ways to connect'),
              ),
              for (final option in available)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: BoneSpacing.xl,
                  ),
                  leading: Icon(_modeIcon(option)),
                  title: Text(_titleFor(option)),
                  subtitle: Text(_descriptionFor(option)),
                  onTap: () => Navigator.of(sheetContext).pop(option),
                ),
              const SizedBox(height: BoneSpacing.lg),
            ],
          ),
        );
      },
    );
    if (chosen != null && mounted) {
      setState(() => mode = chosen);
    }
  }

  bool get _isRegistration => mode == AuthMode.owner || mode == AuthMode.join;

  String? _validateUrl(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) {
      return 'Enter the instance URL.';
    }
    final parsed = Uri.tryParse(raw);
    if (parsed == null) {
      return 'Enter a full URL, e.g. https://chat.example.org';
    }
    try {
      canonicalizeServerOrigin(raw);
    } on FormatException {
      return 'Enter only the server origin, e.g. https://chat.example.org';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    final raw = value ?? '';
    if (raw.isEmpty) {
      return 'Enter your password.';
    }
    // Checked in UTF-8 bytes to match the server's bcrypt limit; the message
    // stays in user language rather than exposing the encoding detail.
    final byteLength = utf8.encode(raw).length;
    if (_isRegistration && byteLength < 12) {
      return 'Use at least 12 characters.';
    }
    if (_isRegistration && byteLength > 72) {
      return 'That password is too long. Use a shorter one.';
    }
    return null;
  }

  String get _modeTitle => _titleFor(mode);

  String get _modeDescription => _descriptionFor(mode);

  static String _titleFor(AuthMode mode) {
    switch (mode) {
      case AuthMode.owner:
        return 'Create the owner account';
      case AuthMode.signIn:
        return 'Sign in';
      case AuthMode.join:
        return 'Join with an invite';
      case AuthMode.linkDevice:
        return 'Link this device';
    }
  }

  static String _descriptionFor(AuthMode mode) {
    switch (mode) {
      case AuthMode.owner:
        return 'First run only: create the owner account on a fresh '
            'self-hosted instance.';
      case AuthMode.signIn:
        return 'Sign in with your password on a device that has already '
            'been linked to your account.';
      case AuthMode.join:
        return 'Registration is invite-only. Enter the invite code you '
            'received from an admin.';
      case AuthMode.linkDevice:
        return 'Enter the link code generated on your existing device '
            '(Settings → Link device).';
    }
  }

  static IconData _modeIcon(AuthMode mode) {
    switch (mode) {
      case AuthMode.owner:
        return Icons.rocket_launch_outlined;
      case AuthMode.signIn:
        return Icons.login;
      case AuthMode.join:
        return Icons.card_giftcard_outlined;
      case AuthMode.linkDevice:
        return Icons.qr_code_2;
    }
  }

  Future<void> _submit() async {
    if (!(formKey.currentState?.validate() ?? false)) {
      return;
    }
    final raw = url.text.trim();
    if (!await _confirmInsecureUrl(raw)) {
      return;
    }
    switch (mode) {
      case AuthMode.owner:
        return widget.state.createOwner(
            raw, username.text.trim(), password.text, setupToken.text.trim());
      case AuthMode.signIn:
        return widget.state.login(raw, username.text.trim(), password.text);
      case AuthMode.join:
        return widget.state.registerWithInvite(
          raw,
          inviteCode.text.trim(),
          username.text.trim(),
          password.text,
        );
      case AuthMode.linkDevice:
        return widget.state.claimDeviceLink(raw, linkCode.text.trim());
    }
  }

  /// Release builds permit cleartext only to a literal loopback address.
  Future<bool> _confirmInsecureUrl(String raw) async {
    if (raw.isEmpty) {
      return true; // let downstream validation produce a clearer error
    }
    final parsed = Uri.tryParse(raw);
    if (parsed == null || !parsed.hasScheme) {
      return true;
    }
    if (parsed.scheme == 'https') {
      return true;
    }
    if (parsed.scheme != 'http') {
      return true;
    }
    final host = parsed.host.toLowerCase();
    if (_isLoopbackHost(host)) {
      return true;
    }
    if (kReleaseMode) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('HTTPS is required in release builds.')),
        );
      }
      return false;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Use insecure connection?'),
        content: Text(
          'You are about to connect to $host over plain HTTP.\n\n'
          'Your password, session token, and message metadata would be sent '
          'in cleartext. Use https:// in production.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Continue anyway'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  bool _isLoopbackHost(String host) {
    if (host == 'localhost') {
      return true;
    }
    return InternetAddress.tryParse(host)?.isLoopback ?? false;
  }

  /// Opens the camera scanner and fills the link-code field from the result.
  /// The generating device encodes a `veritra://device-link?code=…` URI, but
  /// a bare code is accepted too.
  Future<void> _scanLinkCode() async {
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const QrScanScreen()),
    );
    if (!mounted || scanned == null || scanned.isEmpty) {
      return;
    }
    setState(() => linkCode.text = parseDeviceLinkCode(scanned));
  }

  Future<void> _completeDeviceLink() {
    return widget.state.completeDeviceLinkClaim();
  }

  String get _submitLabel {
    switch (mode) {
      case AuthMode.owner:
        return 'Create owner';
      case AuthMode.signIn:
        return 'Sign in';
      case AuthMode.join:
        return 'Join with invite';
      case AuthMode.linkDevice:
        return 'Claim link';
    }
  }
}

/// A field with its label above the box in the `micro` style, rather than a
/// Material `labelText` notched into the border (`docs/design.md` §5).
///
/// The label is a plain `Text`, so a screen reader meets it immediately before
/// the field it names. Every field also carries a `hintText`, so a field
/// reached directly still announces what it wants — dropping `labelText` is
/// what costs the built-in accessible name, and the hint is what buys it back.
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(
            left: BoneSpacing.xs,
            bottom: BoneSpacing.sm,
          ),
          child: Text(
            label.toUpperCase(),
            style: theme.textTheme.labelSmall,
          ),
        ),
        child,
      ],
    );
  }
}

/// Brand moment. One of the few places a direction this restrained shows the
/// mark at all, so it gets the wordmark and a line of positioning rather than
/// a tinted circle with a stock shield in it.
class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: <Widget>[
        VeritraMark(size: 72, color: theme.colorScheme.onSurface),
        const SizedBox(height: BoneSpacing.lg),
        Text(
          'Veritra',
          style: theme.textTheme.displayMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: BoneSpacing.xs),
        Text(
          'Self-hosted, end-to-end encrypted messaging',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// A bordered note on tone. Replaces the filled `secondaryContainer` cards,
/// which in this direction would be a block of near-white.
class _Callout extends StatelessWidget {
  const _Callout({
    required this.icon,
    required this.title,
    required this.message,
    this.child,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(BoneSpacing.lg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(BoneRadii.lg),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ExcludeSemantics(
            child: Icon(icon, size: 20, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: BoneSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(height: BoneSpacing.xs),
                Text(
                  message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (child != null) ...<Widget>[
                  const SizedBox(height: BoneSpacing.md),
                  child!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(BoneSpacing.md),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(BoneRadii.md),
        border: Border.all(color: scheme.error),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, size: 20, color: scheme.onErrorContainer),
          const SizedBox(width: BoneSpacing.md),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
