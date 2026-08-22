import 'dart:async';
import 'dart:convert';

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
  final url = TextEditingController();
  final username = TextEditingController();
  final password = TextEditingController();
  final passwordConfirmation = TextEditingController();
  final setupToken = TextEditingController();
  final inviteCode = TextEditingController();
  final linkCode = TextEditingController();
  // An unlinked device cannot use password sign-in. The probe promotes this
  // to owner for a fresh instance, or sign-in when local device credentials
  // match the probed origin.
  AuthMode mode = AuthMode.join;
  bool showPassword = false;
  SetupProbeResult _probeResult = const SetupProbeResult.idle();
  bool? setupRequired;
  bool _hasStoredDevice = false;
  bool _modeManuallySelected = false;
  Timer? _setupProbeDebounce;
  int _setupProbeGeneration = 0;

  @override
  void initState() {
    super.initState();
    url.addListener(_scheduleSetupProbe);
    unawaited(_loadStoredDeviceIdentity());
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
    _modeManuallySelected = false;
    _setupProbeDebounce?.cancel();
    _setupProbeGeneration++;
    final target = url.text.trim();
    if (target.isEmpty) {
      setState(() {
        _probeResult = const SetupProbeResult.idle();
        setupRequired = null;
        if (_hasStoredDevice) {
          mode = AuthMode.signIn;
        } else {
          mode = AuthMode.join;
        }
      });
      return;
    }
    setState(() {
      _probeResult = const SetupProbeResult.probing();
      setupRequired = null;
    });
    _setupProbeDebounce =
        Timer(const Duration(milliseconds: 600), _probeSetupStatus);
  }

  Future<void> _loadStoredDeviceIdentity() async {
    final linked = await widget.state.hasStoredDeviceIdentity();
    if (!mounted) return;
    setState(() {
      _hasStoredDevice = linked;
      if (url.text.trim().isEmpty && !_modeManuallySelected) {
        mode = linked ? AuthMode.signIn : AuthMode.join;
      }
    });
  }

  Future<void> _probeSetupStatus() async {
    final target = url.text.trim();
    final generation = ++_setupProbeGeneration;
    if (target.isEmpty) return;
    final result = await widget.state.probeSetup(target);
    final linked = result.isReachable
        ? await widget.state.hasStoredDeviceIdentityForOrigin(target)
        : _hasStoredDevice;
    if (!mounted || generation != _setupProbeGeneration) {
      return;
    }
    setState(() {
      _probeResult = result;
      setupRequired = result.setupRequired;
      _hasStoredDevice = linked;
      if (_modeManuallySelected) return;
      if (result.setupRequired == true) {
        mode = AuthMode.owner;
      } else if (result.isReachable) {
        mode = linked ? AuthMode.signIn : AuthMode.join;
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
                  if (_probeResult.state != SetupProbeState.idle) ...<Widget>[
                    const SizedBox(height: BoneSpacing.sm),
                    _ProbeStatus(result: _probeResult),
                  ],
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
                    _ErrorCard(
                      message: widget.state.error!,
                      action: widget.state.error!.contains('linked')
                          ? TextButton(
                              onPressed: () => setState(() {
                                _modeManuallySelected = true;
                                mode = AuthMode.linkDevice;
                              }),
                              child: const Text('Link this device instead'),
                            )
                          : null,
                    ),
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
          autofillHints: const <String>[AutofillHints.username],
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
          autofillHints: <String>[
            _isRegistration
                ? AutofillHints.newPassword
                : AutofillHints.password,
          ],
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
              hintText: 'Repeat your password',
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
      setState(() {
        _modeManuallySelected = true;
        mode = chosen;
      });
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
    if (parsed.scheme.toLowerCase() != 'https') {
      return 'Veritra requires HTTPS. Use an https:// server origin.';
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
    final result = await widget.state.probeSetup(raw);
    if (!mounted) return;
    if (!result.isReachable) {
      setState(() {
        _probeResult = result;
        setupRequired = result.setupRequired;
      });
      return;
    }
    final linked = await widget.state.hasStoredDeviceIdentityForOrigin(raw);
    if (!mounted) return;
    if (!_modeManuallySelected && result.setupRequired == true) {
      setState(() {
        _probeResult = result;
        setupRequired = true;
        mode = AuthMode.owner;
      });
      return;
    }
    if (!_modeManuallySelected && result.setupRequired == false) {
      final discoveredMode = linked ? AuthMode.signIn : AuthMode.join;
      if (mode != discoveredMode) {
        setState(() {
          _probeResult = result;
          setupRequired = false;
          _hasStoredDevice = linked;
          mode = discoveredMode;
        });
        return;
      }
    }
    setState(() {
      _probeResult = result;
      setupRequired = result.setupRequired;
      _hasStoredDevice = linked;
    });
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
    final origin = parseDeviceLinkOrigin(scanned);
    if (origin != null && !await _confirmScannedOrigin(origin)) {
      return;
    }
    final code = parseDeviceLinkCode(scanned);
    if (!mounted) return;
    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That is not a Veritra device-link QR.')),
      );
      return;
    }
    setState(() {
      _modeManuallySelected = true;
      linkCode.text = code;
    });
    if (origin != null) {
      url.text = origin;
      _modeManuallySelected = true;
    }
    if (origin != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Server origin filled. Verify it before continuing.'),
        ),
      );
    }
  }

  Future<bool> _confirmScannedOrigin(String origin) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirm server'),
        content: Text(
          'This QR code suggests $origin. The app will still probe the '
          'server before using it. Continue with this HTTPS origin?',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Use origin'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
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
/// The label remains visually above the control, while the explicit
/// [Semantics] wrapper gives a screen reader a durable name after the hint
/// disappears during editing.
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
        Semantics(
          label: label,
          child: child,
        ),
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

class _ProbeStatus extends StatelessWidget {
  const _ProbeStatus({required this.result});

  final SetupProbeResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (result.state == SetupProbeState.probing) {
      return Semantics(
        liveRegion: true,
        label: result.message,
        child: Row(
          children: <Widget>[
            const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: BoneSpacing.sm),
            Text(result.message, style: theme.textTheme.bodySmall),
          ],
        ),
      );
    }
    final reachable = result.isReachable;
    final color = reachable ? scheme.primary : scheme.error;
    return Semantics(
      liveRegion: true,
      label: result.message,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            reachable ? Icons.check_circle_outline : Icons.info_outline,
            size: 18,
            color: color,
          ),
          const SizedBox(width: BoneSpacing.sm),
          Expanded(
            child: Text(
              result.message,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, this.action});

  final String message;
  final Widget? action;

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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onErrorContainer,
                  ),
                ),
                if (action != null) action!,
              ],
            ),
          ),
        ],
      ),
    );
  }
}
