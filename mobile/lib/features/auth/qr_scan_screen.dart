import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Pulls the `code` query parameter out of a scanned device-link URI
/// (`veritra://device-link?code=…`), falling back to the raw scan when it is
/// not a recognizable URI (e.g. a bare code was encoded).
String parseDeviceLinkCode(String scanned) {
  final uri = Uri.tryParse(scanned);
  if (uri != null) {
    final code = uri.queryParameters['code'];
    if (code != null && code.trim().isNotEmpty) {
      return code.trim();
    }
  }
  return scanned.trim();
}

/// Full-screen camera scanner for device-link QR codes. Pops with the raw
/// scanned string (a `veritra://device-link?code=…` URI or a bare code), or
/// null if the user backs out. Parsing is left to the caller so this screen
/// stays a thin camera surface.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

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
        title: const Text('Scan link QR'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Toggle torch',
            icon: const Icon(Icons.flashlight_on_outlined),
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            tooltip: 'Switch camera',
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
            errorBuilder: (context, error, child) =>
                _ScannerError(error: error),
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
                'Point the camera at the QR code on your existing device '
                '(Settings → Link a new device).',
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
        'Camera permission is required to scan. Enable it in system '
            'settings, or type the link code manually.',
      MobileScannerErrorCode.unsupported =>
        'This device can’t scan QR codes. Type the link code manually.',
      _ => 'The camera could not be started. Type the link code manually.',
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
                child: const Text('Enter code manually'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
