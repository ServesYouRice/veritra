import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/app_state.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/history_copy_banner.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/tile_group.dart';
import '../../l10n/l10n.dart';

/// The QR payload for a link code, built here rather than taken from the
/// server's `link_uri`, so a server cannot place anything else (such as an
/// origin) into the code another device scans.
///
/// Neither Android nor iOS registers the `veritra:` scheme, so the URI is
/// only meaningful to the app's own scanner (`parseDeviceLinkCode`). It is
/// never shown or offered for copying as a link that could be opened.
String? deviceLinkQrPayload(String? code) {
  final trimmed = code?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  return Uri(
    scheme: 'veritra',
    host: 'device-link',
    queryParameters: <String, String>{'code': trimmed},
  ).toString();
}

/// Digits in the safety code the new device shows.
const deviceLinkCodeLength = 8;

/// How often the existing device looks for a claim while its link waits
/// (U22: the status updates by itself). The new device polls on its own
/// (`app_state_link_v3.dart`).
const deviceLinkStatusPollInterval = Duration(seconds: 4);

/// The three steps both devices show while linking (U22).
enum DeviceLinkStep { scan, compare, done }

/// Scan, compare, done, with the current step marked. Both devices show it,
/// so the person sees the same place on each.
class DeviceLinkSteps extends StatelessWidget {
  const DeviceLinkSteps({required this.current, super.key});

  final DeviceLinkStep current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    String name(DeviceLinkStep step) => switch (step) {
          DeviceLinkStep.scan => l10n.deviceLinkStepScan,
          DeviceLinkStep.compare => l10n.deviceLinkStepCompare,
          DeviceLinkStep.done => l10n.deviceLinkStepDone,
        };
    return Semantics(
      key: const ValueKey<String>('device-link-steps'),
      label: l10n.deviceLinkStepOf(current.index + 1, name(current)),
      excludeSemantics: true,
      // Three equal columns: a name that does not fit (large text, a long
      // translation) wraps under its own circle instead of pushing the row.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final step in DeviceLinkStep.values)
            Expanded(
              child: Column(
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: step.index == 0
                            ? const SizedBox.shrink()
                            : Divider(
                                endIndent: BoneSpacing.xs,
                                color: step.index <= current.index
                                    ? scheme.primary
                                    : scheme.outlineVariant,
                              ),
                      ),
                      CircleAvatar(
                        radius: 14,
                        backgroundColor: step.index <= current.index
                            ? scheme.primary
                            : scheme.surfaceContainerHigh,
                        foregroundColor: step.index <= current.index
                            ? scheme.onPrimary
                            : scheme.onSurfaceVariant,
                        child: step.index < current.index ||
                                (step == DeviceLinkStep.done && step == current)
                            ? const Icon(Icons.check, size: 16)
                            : FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text('${step.index + 1}',
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                            color: step.index <= current.index
                                                ? scheme.onPrimary
                                                : scheme.onSurfaceVariant)),
                              ),
                      ),
                      Expanded(
                        child: step.index == DeviceLinkStep.values.length - 1
                            ? const SizedBox.shrink()
                            : Divider(
                                indent: BoneSpacing.xs,
                                color: step.index < current.index
                                    ? scheme.primary
                                    : scheme.outlineVariant,
                              ),
                      ),
                    ],
                  ),
                  const SizedBox(height: BoneSpacing.xs),
                  Text(
                    name(step),
                    key: ValueKey<String>('device-link-step-${step.name}'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: step == current
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                      fontWeight: step == current ? FontWeight.w600 : null,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The existing device's side of linking: show the QR (the typed code waits
/// behind "Cannot scan?"), then type the code the new device shows, then
/// done. While the link waits for a claim, it checks by itself.
class DeviceLinkScreen extends StatefulWidget {
  const DeviceLinkScreen({required this.state, super.key});

  final AppState state;

  @override
  State<DeviceLinkScreen> createState() => _DeviceLinkScreenState();
}

class _DeviceLinkScreenState extends State<DeviceLinkScreen> {
  final _code = TextEditingController();
  Timer? _poll;
  bool _showTypedCode = false;

  /// The link the typed code belongs to; a new link starts empty.
  String? _codeForLink;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(deviceLinkStatusPollInterval, (_) => _checkClaim());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _code.clear();
    _code.dispose();
    super.dispose();
  }

  /// Looks for a claim while the link waits for one. The same check as the
  /// old "Refresh status" button: a claim is accepted only after the native
  /// checks pass, and nothing here approves anything.
  void _checkClaim() {
    final link = state.activeDeviceLink;
    if (!mounted ||
        link == null ||
        link.state != 'pending' ||
        state.activeDeviceLinkCode == null ||
        state.isBusy(Ops.deviceLink)) {
      return;
    }
    unawaited(state.refreshActiveDeviceLink());
  }

  Future<void> _approve() async {
    final typed = _code.text.trim();
    if (typed.length != deviceLinkCodeLength) return;
    await state.approveActiveDeviceLink(typed);
    if (!mounted) return;
    if (state.activeDeviceLink?.state == 'approved') _code.clear();
  }

  DeviceLinkStep _step(DeviceLinkV3View? link) => switch (link?.state) {
        'claimed' => DeviceLinkStep.compare,
        'approved' || 'consumed' => DeviceLinkStep.done,
        _ => DeviceLinkStep.scan,
      };

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final theme = Theme.of(context);
        final l10n = context.l10n;
        final link = state.activeDeviceLink;
        if (link?.id != _codeForLink) {
          _codeForLink = link?.id;
          _code.clear();
          _showTypedCode = false;
        }
        final busy = state.isBusy(Ops.deviceLink);
        final step = _step(link);
        return Scaffold(
          appBar: LargeTitleBar(title: l10n.deviceLinkTitle),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              BoneSpacing.gutter,
              BoneSpacing.sm,
              BoneSpacing.gutter,
              BoneSpacing.xl,
            ),
            children: <Widget>[
              DeviceLinkSteps(current: step),
              const SizedBox(height: BoneSpacing.lg),
              if (link == null) ...<Widget>[
                Text(
                  l10n.deviceLinkIntro,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: BoneSpacing.lg),
                FilledButton.icon(
                  onPressed: busy ? null : state.createDeviceLink,
                  icon: const Icon(Icons.qr_code_2),
                  label: Text(l10n.deviceLinkCreate),
                ),
              ] else
                ...switch (step) {
                  DeviceLinkStep.scan => _scanStep(context, link, busy),
                  DeviceLinkStep.compare => _compareStep(context, link, busy),
                  DeviceLinkStep.done => _doneStep(context),
                },
              if (state.historyTransferStatus != null &&
                  step != DeviceLinkStep.done) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  historyCopyMessage(l10n, state.historyTransferStatus!),
                  style: theme.textTheme.bodyMedium,
                ),
              ],
              if (state.errorFor(Ops.deviceLink) case final error?) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  error,
                  key: const ValueKey<String>('device-link-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              if (link != null) ...<Widget>[
                const SizedBox(height: BoneSpacing.xl),
                Center(
                  child: TextButton.icon(
                    onPressed: busy ? null : state.createDeviceLink,
                    icon: const Icon(Icons.qr_code_2),
                    label: Text(l10n.deviceLinkCreateNew),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// Step 1: the QR first, large; the typed code behind "Cannot scan?".
  List<Widget> _scanStep(
      BuildContext context, DeviceLinkV3View link, bool busy) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final code = state.activeDeviceLinkCode;
    final qrPayload =
        link.state == 'pending' ? deviceLinkQrPayload(code) : null;
    if (qrPayload == null || code == null) {
      // Expired, cancelled, or a link this device no longer holds the
      // secret for: only a new link can go on.
      return <Widget>[
        Text(l10n.deviceLinkEndedHere,
            key: const ValueKey<String>('device-link-ended'),
            style: theme.textTheme.bodyMedium),
      ];
    }
    return <Widget>[
      Text(l10n.deviceLinkScanTitle, style: theme.textTheme.titleMedium),
      const SizedBox(height: BoneSpacing.md),
      TileGroup(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(BoneSpacing.lg),
            child: Column(
              children: <Widget>[
                Semantics(
                  label: l10n.deviceLinkQrSemantics,
                  child: Container(
                    // QR codes need a light, uniform quiet zone to scan
                    // reliably, independent of app theme.
                    padding: const EdgeInsets.all(BoneSpacing.md),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(BoneRadii.md),
                    ),
                    child: QrImageView(
                      key: ValueKey<String>(qrPayload),
                      data: qrPayload,
                      version: QrVersions.auto,
                      size: 220,
                    ),
                  ),
                ),
                const SizedBox(height: BoneSpacing.md),
                Text(
                  l10n.deviceLinkExpiresAt(
                      formatDateTime(context, link.expiresAt)),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: BoneSpacing.md),
      Row(
        children: <Widget>[
          const SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: BoneSpacing.sm),
          Expanded(
            child: Text(
              l10n.deviceLinkWaitingClaim,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: BoneSpacing.sm),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton(
          key: const ValueKey<String>('device-link-cannot-scan'),
          onPressed: () => setState(() => _showTypedCode = !_showTypedCode),
          child: Text(l10n.deviceLinkCannotScan),
        ),
      ),
      if (_showTypedCode) ...<Widget>[
        Text(
          l10n.deviceLinkTypeCodeHint,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: BoneSpacing.sm),
        TileGroup(
          children: <Widget>[
            _LinkValueTile(
              icon: Icons.pin_outlined,
              title: l10n.connectLinkCode,
              value: code,
              copyable: true,
            ),
          ],
        ),
      ],
    ];
  }

  /// Step 2: type the code the new device shows. The warning stands above
  /// the boxes, in full. This device never shows the code itself: typing
  /// what the new device shows is the comparison, and native checks it.
  List<Widget> _compareStep(
      BuildContext context, DeviceLinkV3View link, bool busy) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final ready = link.verificationCode.isNotEmpty;
    return <Widget>[
      if (link.claimedDeviceName case final name?) ...<Widget>[
        Text(l10n.deviceLinkNewDevice(name),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            )),
        const SizedBox(height: BoneSpacing.md),
      ],
      if (!ready) ...<Widget>[
        Text(l10n.deviceLinkChecking, style: theme.textTheme.bodyMedium),
        const SizedBox(height: BoneSpacing.sm),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            onPressed: busy ? null : state.refreshActiveDeviceLink,
            icon: const Icon(Icons.refresh),
            label: Text(l10n.commonRetry),
          ),
        ),
      ] else ...<Widget>[
        Text(l10n.deviceLinkCompareTitle, style: theme.textTheme.titleMedium),
        const SizedBox(height: BoneSpacing.sm),
        Text(l10n.deviceLinkApproveHint, style: theme.textTheme.bodyMedium),
        const SizedBox(height: BoneSpacing.md),
        DeviceLinkWarning(text: l10n.deviceLinkApproveWarning),
        const SizedBox(height: BoneSpacing.lg),
        LinkCodeBoxes(
          controller: _code,
          label: l10n.deviceLinkCodeField,
          enabled: !busy,
          onSubmitted: _approve,
        ),
        const SizedBox(height: BoneSpacing.lg),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _code,
          builder: (context, value, _) => FilledButton.icon(
            key: const ValueKey<String>('device-link-approve'),
            onPressed: busy || value.text.trim().length != deviceLinkCodeLength
                ? null
                : _approve,
            icon: const Icon(Icons.verified_user_outlined),
            label: Text(l10n.deviceLinkApproveDevice),
          ),
        ),
      ],
    ];
  }

  /// Step 3: linked. The history copy reports here while it runs.
  List<Widget> _doneStep(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final transfer = state.historyTransferStatus;
    return <Widget>[
      Row(
        children: <Widget>[
          Icon(Icons.check_circle_outline,
              color: theme.extension<VeritraStateColors>()?.verified ??
                  theme.colorScheme.primary),
          const SizedBox(width: BoneSpacing.sm),
          Expanded(
            child: Text(l10n.deviceLinkDoneTitle,
                key: const ValueKey<String>('device-link-done'),
                style: theme.textTheme.titleMedium),
          ),
        ],
      ),
      const SizedBox(height: BoneSpacing.sm),
      Text(
        transfer == null
            ? l10n.deviceLinkDoneDetail
            : historyCopyMessage(l10n, transfer),
        style: theme.textTheme.bodyMedium,
      ),
    ];
  }
}

/// A warning that is read before acting: an icon and the whole text, never
/// cut to a few lines.
class DeviceLinkWarning extends StatelessWidget {
  const DeviceLinkWarning({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      key: const ValueKey<String>('device-link-warning'),
      padding: const EdgeInsets.all(BoneSpacing.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(BoneRadii.md),
        border: Border.all(color: scheme.error),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ExcludeSemantics(
            child: Icon(Icons.warning_amber_outlined,
                size: 20, color: scheme.error),
          ),
          const SizedBox(width: BoneSpacing.sm),
          Expanded(
            child: Text(text,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurface)),
          ),
        ],
      ),
    );
  }
}

/// The 8-digit code as eight boxes (U3). One text field sits over the boxes,
/// so typing, pasting and the screen reader all work as in a normal field;
/// only digits are taken.
class LinkCodeBoxes extends StatelessWidget {
  const LinkCodeBoxes({
    required this.controller,
    required this.label,
    this.enabled = true,
    this.onSubmitted,
    super.key,
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const none = InputBorder.none;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final text = value.text;
        return Stack(
          children: <Widget>[
            ExcludeSemantics(
              child: Row(
                children: <Widget>[
                  for (var i = 0; i < deviceLinkCodeLength; i++)
                    Expanded(
                      child: Padding(
                        padding: EdgeInsetsDirectional.only(
                          start: i == 0 ? 0 : (i == 4 ? BoneSpacing.md : 3),
                        ),
                        child: Container(
                          key: ValueKey<String>('device-link-code-box-$i'),
                          height: 52,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainer,
                            borderRadius: BorderRadius.circular(BoneRadii.sm),
                            border: Border.all(
                              color: i == text.length ||
                                      (i == deviceLinkCodeLength - 1 &&
                                          text.length == deviceLinkCodeLength)
                                  ? scheme.primary
                                  : scheme.outlineVariant,
                              width: i == text.length ? 2 : 1,
                            ),
                          ),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              i < text.length ? text[i] : '',
                              style: BoneType.mono.copyWith(
                                fontSize: 24,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Positioned.fill(
              // The screen reader names the field; the boxes are silent.
              child: Semantics(
                label: label,
                child: TextField(
                  key: const ValueKey<String>('device-link-code-field'),
                  controller: controller,
                  enabled: enabled,
                  keyboardType: TextInputType.number,
                  autofillHints: const <String>[AutofillHints.oneTimeCode],
                  maxLength: deviceLinkCodeLength,
                  maxLengthEnforcement: MaxLengthEnforcement.enforced,
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  showCursor: false,
                  enableInteractiveSelection: false,
                  autocorrect: false,
                  enableSuggestions: false,
                  onSubmitted: (_) => onSubmitted?.call(),
                  // The boxes draw the digits; the field itself is invisible.
                  style: const TextStyle(color: Colors.transparent),
                  decoration: const InputDecoration(
                    semanticCounterText: '',
                    counterText: '',
                    filled: false,
                    border: none,
                    enabledBorder: none,
                    focusedBorder: none,
                    disabledBorder: none,
                    errorBorder: none,
                    focusedErrorBorder: none,
                    contentPadding: EdgeInsets.zero,
                    isCollapsed: true,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One link fact: a `micro` label over the value. Codes and URIs render in
/// `mono`, which is the ramp step that exists for identifiers.
class _LinkValueTile extends StatelessWidget {
  const _LinkValueTile({
    required this.icon,
    required this.title,
    required this.value,
    this.copyable = false,
  });

  final IconData icon;
  final String title;
  final String value;
  final bool copyable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(icon),
      title: Text(title.toUpperCase(), style: theme.textTheme.labelSmall),
      subtitle: SelectableText(
        value,
        style: BoneType.mono.copyWith(color: theme.colorScheme.onSurface),
      ),
      trailing: copyable && value.isNotEmpty
          ? IconButton(
              tooltip: context.l10n.commonCopy,
              icon: const Icon(Icons.copy_outlined),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: value));
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(
                  SnackBar(content: Text(context.l10n.settingsCopied(title))),
                );
              },
            )
          : null,
    );
  }
}
