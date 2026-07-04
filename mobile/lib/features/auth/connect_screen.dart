import 'package:flutter/material.dart';

import '../../core/app_state.dart';

enum AuthMode { owner, signIn, join, linkDevice }

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({required this.state, super.key});

  final AppState state;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final url = TextEditingController(text: 'http://localhost:8080');
  final username = TextEditingController();
  final password = TextEditingController();
  final inviteCode = TextEditingController();
  final linkCode = TextEditingController();
  AuthMode mode = AuthMode.owner;
  bool showPassword = false;

  @override
  void dispose() {
    url.dispose();
    username.dispose();
    password.dispose();
    inviteCode.dispose();
    linkCode.dispose();
    super.dispose();
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
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: <Widget>[
                _BrandHeader(theme: theme),
                const SizedBox(height: 24),
                SegmentedButton<AuthMode>(
                  segments: const <ButtonSegment<AuthMode>>[
                    ButtonSegment<AuthMode>(
                      value: AuthMode.owner,
                      label: Text('Owner'),
                    ),
                    ButtonSegment<AuthMode>(
                      value: AuthMode.signIn,
                      label: Text('Sign in'),
                    ),
                    ButtonSegment<AuthMode>(
                      value: AuthMode.join,
                      label: Text('Join'),
                    ),
                    ButtonSegment<AuthMode>(
                      value: AuthMode.linkDevice,
                      label: Text('Link'),
                    ),
                  ],
                  selected: <AuthMode>{mode},
                  onSelectionChanged: (value) =>
                      setState(() => mode = value.first),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    _modeDescription,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextField(
                  controller: url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Instance URL',
                    prefixIcon: Icon(Icons.dns_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                if (mode == AuthMode.linkDevice) ...<Widget>[
                  TextField(
                    controller: linkCode,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Link code',
                      prefixIcon: Icon(Icons.qr_code_2),
                    ),
                  ),
                  if (pendingLink != null) ...<Widget>[
                    const SizedBox(height: 12),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.verified_outlined),
                        title: const Text('Verification code'),
                        subtitle: SelectableText(
                          pendingLink.verificationCode,
                          style: theme.textTheme.headlineSmall,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Confirm this code on your already-linked device, '
                      'then check approval below.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ] else ...<Widget>[
                  if (mode == AuthMode.join) ...<Widget>[
                    TextField(
                      controller: inviteCode,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Invite code',
                        prefixIcon: Icon(Icons.card_giftcard_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: username,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: password,
                    obscureText: !showPassword,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        tooltip:
                            showPassword ? 'Hide password' : 'Show password',
                        icon: Icon(showPassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined),
                        onPressed: () =>
                            setState(() => showPassword = !showPassword),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                if (mode == AuthMode.linkDevice && pendingLink != null)
                  FilledButton.icon(
                    onPressed: widget.state.busy ? null : _completeDeviceLink,
                    icon: const Icon(Icons.sync),
                    label: const Text('Check approval'),
                  )
                else
                  FilledButton.icon(
                    onPressed: widget.state.busy ? null : _submit,
                    icon: widget.state.busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(mode == AuthMode.linkDevice
                            ? Icons.qr_code_2
                            : Icons.login),
                    label: Text(_submitLabel),
                  ),
                if (widget.state.error != null) ...<Widget>[
                  const SizedBox(height: 16),
                  _ErrorCard(message: widget.state.error!),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String get _modeDescription {
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

  Future<void> _submit() async {
    final raw = url.text.trim();
    if (!await _confirmInsecureUrl(raw)) {
      return;
    }
    switch (mode) {
      case AuthMode.owner:
        return widget.state
            .createOwner(raw, username.text.trim(), password.text);
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

  /// Returns true if the URL is safe to use (HTTPS, or a clearly-local
  /// HTTP target like localhost / 127.0.0.1 / *.local), or if the user
  /// has explicitly confirmed an insecure public URL.
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
    if (_isLocalHost(host)) {
      return true;
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

  bool _isLocalHost(String host) {
    if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
      return true;
    }
    if (host.endsWith('.local') || host.endsWith('.localhost')) {
      return true;
    }
    // RFC 1918 private ranges + loopback. Cheap string-prefix check; if the
    // host is an FQDN that happens to start with "10." we still flag it as
    // local, which is conservative for a dev convenience.
    if (host.startsWith('10.') || host.startsWith('192.168.')) {
      return true;
    }
    if (host.startsWith('172.')) {
      final parts = host.split('.');
      if (parts.length >= 2) {
        final secondOctet = int.tryParse(parts[1]);
        if (secondOctet != null && secondOctet >= 16 && secondOctet <= 31) {
          return true;
        }
      }
    }
    return false;
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

class _BrandHeader extends StatelessWidget {
  const _BrandHeader({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        CircleAvatar(
          radius: 36,
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(
            Icons.shield_outlined,
            size: 36,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Veritra',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
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

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            Icon(Icons.error_outline, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
