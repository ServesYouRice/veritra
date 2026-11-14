import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../../core/account_invite_link.dart';
import '../../core/api_client.dart';
import '../../core/account_host.dart';
import '../../core/app_state.dart';
import '../../storage/account_slots.dart';
import '../settings/accounts_screen.dart' show AccountsShortcut;
import '../../ui/tokens.dart';
import '../../ui/widgets/section_header.dart';
import 'account_recovery_screen.dart';
import 'qr_scan_screen.dart';
import 'welcome_steps.dart';
import '../../l10n/l10n.dart';

enum AuthMode { owner, signIn, join, linkDevice }

/// U20: where the person is in the signed-out flow. [loading] lasts until the
/// stored-device lookup answers, so a returning device does not flash the
/// welcome step before its sign-in form.
enum _Step { loading, welcome, accountChoice, form }

/// The placeholder origin shown in server fields; never translated.
const exampleServerOrigin = 'https://chat.example.org';

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
  // U21: joining takes two steps. Step 1 reads one invite link (or, typed by
  // hand, the server address and code); step 2 asks for name and password.
  final inviteLink = TextEditingController();
  bool _joinDetails = false;
  bool _joinManual = false;
  // Errors placed under a field, each cleared when that field is edited.
  String? _inviteLinkError;
  String? _inviteCodeError;
  String? _passwordError;
  // The app-wide error already shown under a field, so the card skips it.
  String? _placedError;
  // Whether the last submission reached the action (not only the pre-flight).
  bool _actionRan = false;
  // U20: the person picks the path (welcome, then the account choices); a
  // returning device opens on sign-in. Once picked, neither a URL edit nor
  // the probe changes it ([_modeManuallySelected] stays true).
  _Step _step = _Step.loading;
  AuthMode mode = AuthMode.join;
  bool showPassword = false;
  SetupProbeResult _probeResult = const SetupProbeResult.idle();
  bool? setupRequired;
  bool _hasStoredDevice = false;
  // B7: the server offers passkeys to this build on this platform.
  bool _passkeysOffered = false;
  bool _modeManuallySelected = false;
  Timer? _setupProbeDebounce;
  int _setupProbeGeneration = 0;
  // The URL text the probe last started for: a controller also notifies for
  // caret, selection and composing changes, which are not edits.
  String _lastUrlText = '';
  // True from the tap on submit until its pre-flight and action are done.
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    url.addListener(_scheduleSetupProbe);
    final demoUrl = widget.state.config.defaultServerUrl;
    if (demoUrl != null && url.text.isEmpty) {
      url.text = demoUrl;
    }
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
    inviteLink.dispose();
    super.dispose();
  }

  void _scheduleSetupProbe() {
    if (url.text == _lastUrlText) return;
    _lastUrlText = url.text;
    _passkeysOffered = false;
    _setupProbeDebounce?.cancel();
    _setupProbeGeneration++;
    final target = url.text.trim();
    if (target.isEmpty) {
      setState(() {
        _probeResult = const SetupProbeResult.idle();
        setupRequired = null;
        if (_modeManuallySelected) return;
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
      if (_step != _Step.loading) return;
      // A device-link claim in progress resumes where it was; a device that
      // has signed in before skips the welcome step (back reaches it).
      if (widget.state.pendingDeviceLinkClaim != null) {
        _choose(AuthMode.linkDevice);
      } else if (linked) {
        _choose(AuthMode.signIn);
      } else {
        _step = _Step.welcome;
      }
    });
  }

  /// Opens the form for [chosen] and fixes the path: the probe and URL edits
  /// no longer change it. Call inside setState.
  void _choose(AuthMode chosen) {
    _modeManuallySelected = true;
    mode = chosen;
    _step = _Step.form;
  }

  /// The step a back press returns to, or null on the first step.
  _Step? get _previousStep {
    switch (_step) {
      case _Step.loading:
      case _Step.welcome:
        return null;
      case _Step.accountChoice:
        return _Step.welcome;
      case _Step.form:
        // A device-link claim in progress is left with "Cancel waiting".
        if (widget.state.pendingDeviceLinkClaim != null) return null;
        // Join step 2 goes back to step 1, on the same form.
        if (mode == AuthMode.join && _joinDetails) return _Step.form;
        return mode == AuthMode.signIn || mode == AuthMode.linkDevice
            ? _Step.accountChoice
            : _Step.welcome;
    }
  }

  void _goBack() {
    final previous = _previousStep;
    if (previous == null) return;
    setState(() {
      if (previous == _Step.form) {
        _joinDetails = false;
      } else {
        _step = previous;
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
      _passkeysOffered = widget.state.passkeysOfferedFor(result);
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
    // Listens itself: the app root no longer rebuilds the shell's pages on
    // each notification (T49C-1).
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final pendingLink = widget.state.pendingDeviceLinkClaim;
    // A claim restored after the screen opened takes the person back to it.
    if (pendingLink != null &&
        _step != _Step.loading &&
        !(_step == _Step.form && mode == AuthMode.linkDevice)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || widget.state.pendingDeviceLinkClaim == null) return;
        setState(() => _choose(AuthMode.linkDevice));
      });
    }
    final previous = _previousStep;
    return PopScope(
      // The system back gesture steps back through the flow first.
      canPop: previous == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goBack();
      },
      child: Scaffold(
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
                    _topBar(previous),
                    ..._stepChildren(pendingLink),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Back one step, and the way to the other accounts on this device.
  Widget _topBar(_Step? previous) {
    final Widget accounts;
    if (_pendingSlotHost case final host?) {
      accounts = Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          key: const ValueKey<String>('connect-back'),
          onPressed: host.switching ? null : () => _backToAccounts(host),
          icon: const Icon(Icons.arrow_back),
          label: Text(context.l10n.accountsBack),
        ),
      );
    } else {
      // A signed-out account (an expired session, a sign-out) still reaches
      // the other accounts on this device.
      accounts = const AccountsShortcut();
    }
    if (previous == null) return accounts;
    return Row(
      children: <Widget>[
        IconButton(
          key: const ValueKey<String>('connect-step-back'),
          tooltip: context.l10n.connectStepBack,
          onPressed: _goBack,
          icon: const Icon(Icons.arrow_back),
        ),
        Expanded(child: accounts),
      ],
    );
  }

  List<Widget> _stepChildren(DeviceLinkClaimView? pendingLink) {
    switch (_step) {
      case _Step.loading:
        return const <Widget>[];
      case _Step.welcome:
        return <Widget>[
          WelcomeChoices(
            onInvite: () => setState(() {
              _choose(AuthMode.join);
              _joinDetails = false;
            }),
            onAccount: () => setState(() => _step = _Step.accountChoice),
            onSetUpServer: () => setState(() => _choose(AuthMode.owner)),
          ),
        ];
      case _Step.accountChoice:
        return _accountChoiceChildren();
      case _Step.form:
        return _formChildren(pendingLink);
    }
  }

  List<Widget> _accountChoiceChildren() {
    final theme = Theme.of(context);
    return <Widget>[
      const SizedBox(height: BoneSpacing.lg),
      AccountChoices(
        onNewDevice: () => setState(() => _choose(AuthMode.linkDevice)),
        onSignedInBefore: () => setState(() => _choose(AuthMode.signIn)),
        // K0 R4: someone who lost every device recovers with the password
        // and recovery key.
        onLostDevices: widget.state.recoveryAvailable
            ? () {
                if (widget.state.busy) return;
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AccountRecoveryStartScreen(
                      state: widget.state,
                      initialServer: url.text.trim(),
                    ),
                  ),
                );
              }
            : null,
      ),
      if (widget.state.errorFor(Ops.accountRecovery) case final recoveryError?)
        Padding(
          padding: const EdgeInsets.only(top: BoneSpacing.md),
          child: Text(
            recoveryError,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error),
          ),
        ),
    ];
  }

  List<Widget> _formChildren(DeviceLinkClaimView? pendingLink) {
    final theme = Theme.of(context);
    if (mode == AuthMode.join) {
      return _joinDetails ? _joinAccountChildren(theme) : _joinLinkChildren();
    }
    return <Widget>[
      ..._formHeader(theme, _modeTitle, _modeDescription),
      _freshInstanceNotice(),
      ..._serverFieldChildren(theme),
      const SizedBox(height: BoneSpacing.lg),
      if (mode == AuthMode.linkDevice)
        ..._linkDeviceFields(theme, pendingLink)
      else
        ..._credentialFields(),
      const SizedBox(height: BoneSpacing.xl),
      _submitButton(pendingLink),
      if (mode == AuthMode.signIn &&
          _hasStoredDevice &&
          _passkeysOffered) ...<Widget>[
        const SizedBox(height: BoneSpacing.md),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            key: const ValueKey<String>('connect-passkey'),
            onPressed:
                widget.state.busy || _submitting ? null : _signInWithPasskey,
            icon: const Icon(Icons.fingerprint),
            label: Text(context.l10n.connectSignInPasskey),
          ),
        ),
      ],
      ..._errorCard(),
    ];
  }

  /// The step's title and, when given, one line under it.
  List<Widget> _formHeader(ThemeData theme, String title, String? detail) {
    return <Widget>[
      const SizedBox(height: BoneSpacing.md),
      SectionHeader(
        title,
        padding: const EdgeInsets.only(bottom: BoneSpacing.xs),
      ),
      if (detail != null) ...<Widget>[
        Text(
          detail,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: BoneSpacing.xl),
      ],
    ];
  }

  // The optional notices below each take one list slot, shown or not: a
  // ListView child list matches elements by index, so a notice inserted
  // above a field would rebuild that field and drop its focus mid-typing.

  Widget _freshInstanceNotice() {
    if (setupRequired != true) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: BoneSpacing.lg),
      child: _Callout(
        icon: Icons.rocket_launch_outlined,
        title: context.l10n.connectFreshInstanceTitle,
        message: context.l10n.connectFreshInstanceMessage,
        // A new server has no accounts to sign in to or join yet.
        child: mode == AuthMode.owner
            ? null
            : Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  key: const ValueKey<String>('connect-set-up-this-server'),
                  onPressed: () => setState(() => _choose(AuthMode.owner)),
                  child: Text(context.l10n.connectFreshInstanceAction),
                ),
              ),
      ),
    );
  }

  List<Widget> _serverFieldChildren(ThemeData theme) {
    return <Widget>[
      _Field(
        label: context.l10n.connectInstanceUrl,
        child: TextFormField(
          controller: url,
          keyboardType: TextInputType.url,
          autocorrect: false,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          validator: _validateUrl,
          decoration: const InputDecoration(
            hintText: exampleServerOrigin,
            prefixIcon: Icon(Icons.dns_outlined),
          ),
        ),
      ),
      _probeResult.state == SetupProbeState.idle
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(top: BoneSpacing.sm),
              child: _ProbeStatus(result: _probeResult),
            ),
      _sharesServerWithAnotherAccount
          ? Padding(
              padding: const EdgeInsets.only(top: BoneSpacing.sm),
              child: Text(context.l10n.accountsSameServer,
                  key: const ValueKey<String>('connect-same-server'),
                  style: theme.textTheme.bodySmall),
            )
          : const SizedBox.shrink(),
    ];
  }

  Widget _submitButton(DeviceLinkClaimView? pendingLink) {
    return SizedBox(
      width: double.infinity,
      child: mode == AuthMode.linkDevice && pendingLink != null
          ? FilledButton.icon(
              onPressed: widget.state.busy ? null : _completeDeviceLink,
              icon: const Icon(Icons.sync),
              label: Text(context.l10n.connectCheckApproval),
            )
          : FilledButton.icon(
              key: const ValueKey<String>('connect-submit'),
              onPressed: widget.state.busy || _submitting ? null : _submit,
              icon: widget.state.busy || _submitting
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
    );
  }

  /// The app-wide error, unless it already sits under its field.
  List<Widget> _errorCard() {
    final error = widget.state.error;
    if (error == null || error == _placedError) return const <Widget>[];
    return <Widget>[
      const SizedBox(height: BoneSpacing.lg),
      _ErrorCard(
        message: error,
        action: _suggestsLinking(error)
            ? TextButton(
                onPressed: () => setState(() {
                  _modeManuallySelected = true;
                  mode = AuthMode.linkDevice;
                }),
                child: Text(context.l10n.connectLinkInstead),
              )
            : null,
      ),
    ];
  }

  /// U21 join, step 1: one invite link, or the server address and code.
  List<Widget> _joinLinkChildren() {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return <Widget>[
      ..._formHeader(
        theme,
        l10n.connectModeJoinTitle,
        _joinManual ? l10n.connectModeJoinDetail : l10n.connectJoinLinkDetail,
      ),
      if (!_joinManual) ...<Widget>[
        _Field(
          label: l10n.connectInviteLink,
          child: TextFormField(
            key: const ValueKey<String>('connect-invite-link'),
            controller: inviteLink,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            validator: (value) => value == null || value.trim().isEmpty
                ? l10n.connectInviteLinkRequired
                : null,
            forceErrorText: _inviteLinkError,
            onChanged: (_) {
              if (_inviteLinkError != null) {
                setState(() => _inviteLinkError = null);
              }
            },
            onFieldSubmitted: (_) => _continueJoin(),
            decoration: InputDecoration(
              hintText: l10n.connectInviteLinkHint,
              prefixIcon: const Icon(Icons.link),
            ),
          ),
        ),
        if (_canScanQr) ...<Widget>[
          const SizedBox(height: BoneSpacing.md),
          OutlinedButton.icon(
            key: const ValueKey<String>('connect-invite-scan'),
            onPressed: _scanInviteLink,
            icon: const Icon(Icons.qr_code_scanner),
            label: Text(l10n.connectScanQr),
          ),
        ],
      ] else ...<Widget>[
        ..._serverFieldChildren(theme),
        const SizedBox(height: BoneSpacing.lg),
        _inviteCodeField(),
      ],
      const SizedBox(height: BoneSpacing.xl),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          key: const ValueKey<String>('connect-join-continue'),
          onPressed: _continueJoin,
          icon: const Icon(Icons.arrow_forward),
          label: Text(l10n.commonContinue),
        ),
      ),
      const SizedBox(height: BoneSpacing.sm),
      Center(
        child: TextButton(
          key: ValueKey<String>(
              _joinManual ? 'connect-invite-paste' : 'connect-invite-manual'),
          onPressed: () => setState(() {
            _joinManual = !_joinManual;
            _inviteLinkError = null;
            _inviteCodeError = null;
          }),
          child: Text(_joinManual
              ? l10n.connectInviteLinkInstead
              : l10n.connectInviteTypeInstead),
        ),
      ),
    ];
  }

  /// U21 join, step 2: the server named, then name and password. Kept short
  /// enough that Join shows without scrolling at 360 x 800.
  List<Widget> _joinAccountChildren(ThemeData theme) {
    final l10n = context.l10n;
    return <Widget>[
      ..._formHeader(theme, l10n.connectJoinAccountTitle, null),
      Row(
        children: <Widget>[
          Expanded(
            child: Text(
              l10n.connectJoiningServer(_serverLabel),
              key: const ValueKey<String>('connect-join-server'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton(
            key: const ValueKey<String>('connect-join-change'),
            onPressed: () => setState(() => _joinDetails = false),
            child: Text(l10n.connectJoinChangeServer),
          ),
        ],
      ),
      // Only a server that cannot be reached needs saying here.
      _probeResult.state == SetupProbeState.idle ||
              _probeResult.state == SetupProbeState.probing ||
              _probeResult.isReachable
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(bottom: BoneSpacing.sm),
              child: _ProbeStatus(result: _probeResult),
            ),
      const SizedBox(height: BoneSpacing.md),
      _freshInstanceNotice(),
      ..._credentialFields(),
      const SizedBox(height: BoneSpacing.xl),
      _submitButton(null),
      ..._errorCard(),
    ];
  }

  /// The server the join will reach, as host (and port), for step 2.
  String get _serverLabel {
    final raw = url.text.trim();
    final authority = Uri.tryParse(raw)?.authority ?? '';
    return authority.isEmpty ? raw : authority;
  }

  Widget _inviteCodeField() {
    return _Field(
      label: context.l10n.connectInviteCode,
      child: TextFormField(
        controller: inviteCode,
        autocorrect: false,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        validator: (value) => value == null || value.trim().isEmpty
            ? context.l10n.connectInviteCodeRequired
            : null,
        forceErrorText: _inviteCodeError,
        onChanged: (_) {
          if (_inviteCodeError != null) {
            setState(() => _inviteCodeError = null);
          }
        },
        style: BoneType.mono,
        decoration: InputDecoration(
          hintText: context.l10n.connectInviteCodeHint,
          prefixIcon: const Icon(Icons.card_giftcard_outlined),
        ),
      ),
    );
  }

  /// Step 1 to step 2: a link fills the server address and the code; typed
  /// by hand, the two fields are checked as they are. Only the setup probe
  /// reaches the server before Join.
  void _continueJoin() {
    if (!(formKey.currentState?.validate() ?? false)) return;
    if (!_joinManual) {
      final link = AccountInviteLink.tryParse(
        inviteLink.text,
        transport: widget.state.config.transport,
      );
      if (link == null) {
        setState(
            () => _inviteLinkError = context.l10n.connectInviteLinkInvalid);
        return;
      }
      url.text = link.origin;
      inviteCode.text = link.code;
    }
    setState(() => _joinDetails = true);
  }

  Future<void> _scanInviteLink() async {
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => QrScanScreen(
          title: context.l10n.connectScanInviteTitle,
          hint: context.l10n.qrPointCameraInvite,
        ),
      ),
    );
    if (!mounted || scanned == null || scanned.isEmpty) return;
    setState(() {
      inviteLink.text = scanned;
      _inviteLinkError = null;
    });
    _continueJoin();
  }

  /// Puts a server answer that belongs to one field under that field (U21):
  /// an invite the server refuses goes back to step 1, a password it refuses
  /// goes under the password. Anything else stays in the card.
  void _placeFieldError(AuthMode submitMode) {
    final error = widget.state.error;
    if (error == null) return;
    final l10n = context.l10n;
    if (submitMode == AuthMode.join && error == l10n.apiErrorInvalidInvite) {
      setState(() {
        _placedError = error;
        _joinDetails = false;
        if (_joinManual) {
          _inviteCodeError = error;
        } else {
          _inviteLinkError = error;
        }
      });
    } else if ((submitMode == AuthMode.join || submitMode == AuthMode.owner) &&
        error == l10n.apiErrorWeakPassword) {
      setState(() {
        _placedError = error;
        _passwordError = error;
      });
    }
  }

  List<Widget> _linkDeviceFields(
      ThemeData theme, DeviceLinkClaimView? pendingLink) {
    return <Widget>[
      _Field(
        label: context.l10n.connectLinkCode,
        child: TextFormField(
          controller: linkCode,
          autocorrect: false,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          validator: (value) => value == null || value.trim().isEmpty
              ? context.l10n.connectLinkCodeRequired
              : null,
          style: BoneType.mono,
          decoration: InputDecoration(
            hintText: context.l10n.connectLinkCodeHint,
            prefixIcon: const Icon(Icons.qr_code_2),
          ),
        ),
      ),
      // The QR scanner plugin has no Windows or Linux camera support; the
      // pasted code works everywhere.
      if (_canScanQr) ...<Widget>[
        const SizedBox(height: BoneSpacing.md),
        OutlinedButton.icon(
          onPressed: widget.state.busy ? null : _scanLinkCode,
          icon: const Icon(Icons.qr_code_scanner),
          label: Text(context.l10n.connectScanQr),
        ),
      ],
      if (pendingLink != null) ...<Widget>[
        const SizedBox(height: BoneSpacing.lg),
        // The code exists only once the other device revealed its random
        // and it opened the commitment (L1-3); until then, a waiting line.
        if (pendingLink.verificationCode.isNotEmpty)
          _Callout(
            icon: Icons.verified_outlined,
            title: context.l10n.connectVerificationTitle,
            message: context.l10n.connectVerificationMessage,
            child: SelectableText(
              pendingLink.verificationCode,
              style: BoneType.mono.copyWith(
                fontSize: 22,
                letterSpacing: 3,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        const SizedBox(height: BoneSpacing.sm),
        Text(
          pendingLink.verificationCode.isEmpty
              ? context.l10n.deviceLinkWaitingCode
              : context.l10n.deviceLinkWaitingApproval,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: widget.state.busy
                ? null
                : () => widget.state.abandonDeviceLinkClaim(),
            child: Text(context.l10n.deviceLinkCancelWaiting),
          ),
        ),
      ],
    ];
  }

  List<Widget> _credentialFields() {
    return <Widget>[
      _Field(
        label: context.l10n.connectUsername,
        child: TextFormField(
          controller: username,
          autofillHints: const <String>[AutofillHints.username],
          autocorrect: false,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          validator: _validateUsername,
          decoration: InputDecoration(
            hintText: context.l10n.connectUsernameHint,
            prefixIcon: const Icon(Icons.person_outline),
          ),
        ),
      ),
      const SizedBox(height: BoneSpacing.lg),
      _Field(
        label: context.l10n.connectPassword,
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
          forceErrorText: _passwordError,
          onChanged: (_) {
            if (_passwordError != null) setState(() => _passwordError = null);
          },
          decoration: InputDecoration(
            hintText: _isRegistration ? context.l10n.connectPasswordHint : null,
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              tooltip: showPassword
                  ? context.l10n.connectHidePassword
                  : context.l10n.connectShowPassword,
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
          label: context.l10n.connectConfirmPassword,
          child: TextFormField(
            controller: passwordConfirmation,
            obscureText: !showPassword,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            validator: (value) => value == password.text
                ? null
                : context.l10n.settingsPasswordsMismatch,
            decoration: InputDecoration(
              hintText: context.l10n.connectConfirmPasswordHint,
              prefixIcon: const Icon(Icons.lock_reset_outlined),
            ),
          ),
        ),
      ],
      if (mode == AuthMode.owner) ...<Widget>[
        const SizedBox(height: BoneSpacing.lg),
        _Field(
          label: context.l10n.connectSetupToken,
          child: TextFormField(
            controller: setupToken,
            obscureText: true,
            autocorrect: false,
            decoration: InputDecoration(
              hintText: context.l10n.connectSetupTokenHint,
              prefixIcon: const Icon(Icons.vpn_key_outlined),
            ),
          ),
        ),
      ],
    ];
  }

  bool get _isRegistration => mode == AuthMode.owner || mode == AuthMode.join;

  /// Whether [error] says password sign-in needs a linked device.
  bool _suggestsLinking(String error) =>
      error == context.l10n.errorPasswordLoginNeedsLink ||
      error == context.l10n.apiErrorDeviceNotLinked ||
      error == context.l10n.errorRelinkRequired;

  String? _validateUrl(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) {
      return context.l10n.connectUrlRequired;
    }
    final parsed = Uri.tryParse(raw);
    if (parsed == null) {
      return context.l10n.connectUrlInvalid;
    }
    try {
      canonicalizeServerOrigin(raw);
    } on FormatException {
      return parsed.scheme.toLowerCase() == 'https'
          ? context.l10n.connectUrlOriginOnly
          : context.l10n.connectUrlHttpsRequired;
    }
    if (!widget.state.config.transport.allows(raw)) {
      return widget.state.config.transport.allowLoopbackHttp
          ? context.l10n.connectUrlLoopbackOnly
          : context.l10n.connectUrlHttpsRequired;
    }
    return null;
  }

  /// The server's rule for a new username (`validUsername`): 3 to 32 ASCII
  /// letters, digits, `_` or `-`. Sign-in only needs one.
  static final RegExp _usernamePattern = RegExp(r'^[A-Za-z0-9_-]{3,32}$');

  String? _validateUsername(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) return context.l10n.connectUsernameRequired;
    if (_isRegistration && !_usernamePattern.hasMatch(raw)) {
      return context.l10n.connectUsernameInvalid;
    }
    return null;
  }

  String? _validatePassword(String? value) {
    final raw = value ?? '';
    if (raw.isEmpty) {
      return context.l10n.connectPasswordRequired;
    }
    // Checked in UTF-8 bytes to match the server's bcrypt limit; the message
    // stays in user language rather than exposing the encoding detail.
    final byteLength = utf8.encode(raw).length;
    if (_isRegistration && byteLength < 12) {
      return context.l10n.settingsPasswordTooShort;
    }
    if (_isRegistration && byteLength > 72) {
      return context.l10n.settingsPasswordTooLong;
    }
    return null;
  }

  String get _modeTitle => _titleFor(mode);

  String get _modeDescription => _descriptionFor(mode);

  String _titleFor(AuthMode mode) {
    switch (mode) {
      case AuthMode.owner:
        return context.l10n.connectModeOwnerTitle;
      case AuthMode.signIn:
        return context.l10n.connectModeSignInTitle;
      case AuthMode.join:
        return context.l10n.connectModeJoinTitle;
      case AuthMode.linkDevice:
        return context.l10n.connectModeLinkTitle;
    }
  }

  String _descriptionFor(AuthMode mode) {
    switch (mode) {
      case AuthMode.owner:
        return context.l10n.connectModeOwnerDetail;
      case AuthMode.signIn:
        return context.l10n.connectModeSignInDetail;
      case AuthMode.join:
        return context.l10n.connectModeJoinDetail;
      case AuthMode.linkDevice:
        return context.l10n.connectModeLinkDetail;
    }
  }

  Future<void> _submit() async {
    // One submission at a time: the pre-flight below awaits twice before the
    // action sets the app's own busy flag.
    if (_submitting) return;
    if (!(formKey.currentState?.validate() ?? false)) {
      return;
    }
    final submitMode = mode;
    setState(() {
      _submitting = true;
      _placedError = null;
      _actionRan = false;
    });
    try {
      await _submitForm();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
    if (mounted && _actionRan) _placeFieldError(submitMode);
  }

  /// The account switcher's host, when this screen belongs to an account
  /// being added (a pending slot) and another account exists to go back to.
  AccountHost? get _pendingSlotHost {
    final host = AccountHostScope.maybeOf(context);
    if (host == null) return null;
    final active = host.activeSlot;
    if (active == null || active.state != SlotState.pending) return null;
    final others = host.registry.slots.where((s) =>
        s.namespace != active.namespace && s.state != SlotState.removing);
    return others.isEmpty ? null : host;
  }

  /// This server already holds one of the accounts on this device (O10).
  bool get _sharesServerWithAnotherAccount {
    final host = AccountHostScope.maybeOf(context);
    final origin = _probeResult.origin;
    if (host == null || origin == null) return false;
    final active = host.registry.active;
    return host.registry.slots.any((s) =>
        s.namespace != active &&
        s.state != SlotState.removing &&
        s.origin == origin);
  }

  Future<void> _backToAccounts(AccountHost host) async {
    final active = host.registry.active;
    // The empty pending slot is removed; the first other account opens.
    await host.remove(active);
  }

  /// Passkey sign-in: the same post-sign-in path as the password, with no
  /// username or password typed. The URL is the only field read.
  Future<void> _signInWithPasskey() async {
    final raw = url.text.trim();
    if (_validateUrl(raw) != null) return;
    setState(() => _submitting = true);
    try {
      await widget.state.signInWithPasskey(raw);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submitForm() async {
    // Everything the person submitted is read now, together. The form stays
    // editable while the pre-flight runs, so nothing is read from the fields
    // after an await.
    final raw = url.text.trim();
    final submitMode = mode;
    final ownerName = username.text.trim();
    final secret = password.text;
    final setupSecret = setupToken.text.trim();
    final invite = inviteCode.text.trim();
    final link = linkCode.text.trim();
    // The origin the person is looking at must still be the one submitted.
    bool changed() => !mounted || url.text.trim() != raw;

    final result = await widget.state.probeSetup(raw);
    if (changed()) return;
    if (!result.isReachable) {
      setState(() {
        _probeResult = result;
        setupRequired = result.setupRequired;
      });
      return;
    }
    final linked = await widget.state.hasStoredDeviceIdentityForOrigin(raw);
    if (changed()) return;
    // Switch to owner setup and let the user fill it in, but only when the
    // form is not already there; otherwise "Create owner" could never submit.
    if (!_modeManuallySelected &&
        result.setupRequired == true &&
        submitMode != AuthMode.owner) {
      setState(() {
        _probeResult = result;
        setupRequired = true;
        mode = AuthMode.owner;
      });
      return;
    }
    if (!_modeManuallySelected && result.setupRequired == false) {
      final discoveredMode = linked ? AuthMode.signIn : AuthMode.join;
      if (submitMode != discoveredMode) {
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
    _actionRan = true;
    switch (submitMode) {
      case AuthMode.owner:
        return widget.state.createOwner(raw, ownerName, secret, setupSecret);
      case AuthMode.signIn:
        return widget.state.login(raw, ownerName, secret);
      case AuthMode.join:
        return widget.state.registerWithInvite(raw, invite, ownerName, secret);
      case AuthMode.linkDevice:
        return widget.state.claimDeviceLink(raw, link);
    }
  }

  /// Opens the camera scanner and fills the link-code field from the result.
  /// The generating device encodes a `veritra://device-link?code=…` URI, but
  /// a bare code is accepted too.
  bool get _canScanQr =>
      defaultTargetPlatform != TargetPlatform.windows &&
      defaultTargetPlatform != TargetPlatform.linux &&
      defaultTargetPlatform != TargetPlatform.macOS;

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
        SnackBar(content: Text(context.l10n.connectNotDeviceLinkQr)),
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
        SnackBar(content: Text(context.l10n.connectOriginFilled)),
      );
    }
  }

  Future<bool> _confirmScannedOrigin(String origin) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.connectConfirmServerTitle),
        content: Text(context.l10n.connectConfirmServerMessage(origin)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(context.l10n.connectUseOrigin),
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
        return context.l10n.connectSubmitOwner;
      case AuthMode.signIn:
        return context.l10n.connectSubmitSignIn;
      case AuthMode.join:
        return context.l10n.connectSubmitJoin;
      case AuthMode.linkDevice:
        return context.l10n.connectSubmitLink;
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
    final message = result.localizedMessage(context.l10n);
    if (result.state == SetupProbeState.probing) {
      return Semantics(
        liveRegion: true,
        label: message,
        child: Row(
          children: <Widget>[
            const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: BoneSpacing.sm),
            Text(message, style: theme.textTheme.bodySmall),
          ],
        ),
      );
    }
    final reachable = result.isReachable;
    final color = reachable ? scheme.primary : scheme.error;
    return Semantics(
      liveRegion: true,
      label: message,
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
              message,
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
