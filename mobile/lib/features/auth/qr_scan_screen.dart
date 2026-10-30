import 'package:flutter/material.dart';
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

/// Full-screen camera scanner for QR codes (device links, safety numbers). Pops with the raw
/// scanned string (a `veritra://device-link?code=…` URI or a bare code), or
/// null if the user backs out. Parsing is left to the caller so this screen
/// stays a thin camera surface.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({this.title, super.key});

  /// The app bar title; defaults to the device-link wording.
  final String? title;

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
            errorBuilder: (context, error) => _ScannerError(error: error),
          ),
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
                context.l10n.qrPointCamera,
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
      ),
    );
  }
}

class _ScannerError extends StatelessWidget {
  const _ScannerError({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied =>
        context.l10n.qrPermissionDenied,
      MobileScannerErrorCode.unsupported => context.l10n.qrUnsupported,
      _ => context.l10n.qrCameraFailed,
    };
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.no_photography_outlined,
                  size: 48, color: Colors.white70),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style:
                    theme.textTheme.bodyMedium?.copyWith(color: Colors.white),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(context.l10n.qrEnterManually),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
