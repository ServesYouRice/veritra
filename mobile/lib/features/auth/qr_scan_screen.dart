import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/api_client.dart';
import '../../crypto/device_link_code.dart';
import '../../core/transport_policy.dart';
import '../../l10n/l10n.dart';

/// Pulls the `code` query parameter out of a scanned device-link URI
/// (`veritra://device-link?code=…`), falling back to the raw scan when it is
/// not a recognizable URI (e.g. a bare code was encoded).
String parseDeviceLinkCode(String scanned) {
  final uri = Uri.tryParse(scanned);
  if (uri != null) {
    if (uri.scheme.isNotEmpty &&
        (uri.scheme.toLowerCase() != 'veritra' ||
            uri.host.toLowerCase() != 'device-link')) {
      return '';
    }
    final code = uri.queryParameters['code'];
    if (code != null && code.trim().isNotEmpty) {
      return _validLinkCode(code);
    }
    if (uri.scheme.isNotEmpty) {
      return '';
    }
  }
  return _validLinkCode(scanned);
}

String _validLinkCode(String code) {
  try {
    return encodeDeviceLinkSecret(decodeDeviceLinkSecret(code));
  } on FormatException {
    return '';
  }
}

/// Reads an optional HTTPS origin from a future structured link. The caller
/// must show it and obtain explicit confirmation before filling the URL field;
/// this parser never trusts a QR payload by itself.
String? parseDeviceLinkOrigin(
  String scanned, {
  TransportPolicy transport = TransportPolicy.production,
}) {
  final uri = Uri.tryParse(scanned);
  if (uri == null ||
      uri.scheme.toLowerCase() != 'veritra' ||
      uri.host.toLowerCase() != 'device-link') {
    return null;
  }
  final raw = uri.queryParameters['origin'];
  if (raw == null || raw.trim().isEmpty) {
    return null;
  }
  try {
    final origin = canonicalizeServerOrigin(raw);
    return transport.allows(origin) ? origin : null;
  } on FormatException {
    return null;
  }
}

/// The Runner channel that opens this app's page in the system settings,
/// where the camera can be allowed again (Android and iOS).
const appSettingsChannel = MethodChannel(
  'org.veritra.private_messenger/app_settings',
);

/// Opens this app's page in the system settings. False when nothing opened
/// (a platform without the channel, or the system refused).
Future<bool> openAppSettings() async {
  try {
    return await appSettingsChannel.invokeMethod<bool>('open') ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// Full-screen camera scanner for QR codes (device links, safety numbers). Pops with the raw
/// scanned string (a `veritra://device-link?code=…` URI or a bare code), or
/// null if the user backs out. Parsing is left to the caller so this screen
/// stays a thin camera surface.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({this.title, this.hint, super.key});

  /// The app bar title; defaults to the device-link wording.
  final String? title;

  /// The line under the viewfinder; defaults to the device-link wording.
  final String? hint;

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
  );
  // Guards against the scanner firing multiple detections before the route
  // finishes popping.
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) {
      return;
    }
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw != null && raw.trim().isNotEmpty) {
        _handled = true;
        Navigator.of(context).pop(raw.trim());
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? context.l10n.qrScanLinkTitle),
        actions: <Widget>[
          IconButton(
            tooltip: context.l10n.qrToggleTorch,
            icon: const Icon(Icons.flashlight_on_outlined),
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            tooltip: context.l10n.qrSwitchCamera,
            icon: const Icon(Icons.cameraswitch_outlined),
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => QrScannerError(error: error),
          ),
          // The frame and the hint only while the camera can scan: over the
          // error page they would cover its text and buttons.
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _controller,
            builder: (context, value, _) {
              if (value.error != null) return const SizedBox.shrink();
              return Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  // Simple reticle to guide framing.
                  IgnorePointer(
                    child: Center(
                      child: Container(
                        width: 240,
                        height: 240,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white70, width: 2),
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        widget.hint ?? context.l10n.qrPointCamera,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white,
                          shadows: const <Shadow>[
                            Shadow(blurRadius: 8, color: Colors.black87),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// What the scanner shows when the camera cannot be used: the reason, a way
/// to the system settings when permission was refused, and the typed code.
/// It scrolls, so the text stays inside the page at any width and text size.
class QrScannerError extends StatelessWidget {
  const QrScannerError({required this.error, this.openSettings, super.key});

  final MobileScannerException error;

  /// Opens the system settings; replaced in tests.
  @visibleForTesting
  final Future<bool> Function()? openSettings;

  Future<void> _openSettings(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final fallback = context.l10n.qrOpenSettingsFailed;
    final opened = await (openSettings ?? openAppSettings)();
    if (!opened) {
      messenger?.showSnackBar(SnackBar(content: Text(fallback)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    final message = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied =>
        context.l10n.qrPermissionDenied,
      MobileScannerErrorCode.unsupported => context.l10n.qrUnsupported,
      _ => context.l10n.qrCameraFailed,
    };
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight:
                  constraints.maxHeight > 64 ? constraints.maxHeight - 64 : 0,
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const Icon(
                    Icons.no_photography_outlined,
                    size: 48,
                    color: Colors.white70,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    message,
                    key: const ValueKey<String>('qr-error-message'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (denied) ...<Widget>[
                    FilledButton.icon(
                      key: const ValueKey<String>('qr-open-settings'),
                      onPressed: () => _openSettings(context),
                      icon: const Icon(Icons.settings_outlined),
                      label: Text(context.l10n.qrOpenSettings),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white70),
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(context.l10n.qrEnterManually),
                    ),
                  ] else
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(context.l10n.qrEnterManually),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
