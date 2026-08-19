import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/peers/peer_provider.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/security/safety_number_service.dart';
import 'package:vantra/core/themes/vantra_theme.dart';

class VerifyIdentityPage extends ConsumerStatefulWidget {
  final String peerId;

  const VerifyIdentityPage({super.key, required this.peerId});

  @override
  ConsumerState<VerifyIdentityPage> createState() => _VerifyIdentityPageState();
}

class _VerifyIdentityPageState extends ConsumerState<VerifyIdentityPage> {
  final MobileScannerController _scannerController = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
  );

  String? _scannedValue;
  bool _isVerifying = false;

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final peerProfileAsync = ref.watch(peerProfileStreamProvider(widget.peerId));
    final localIdentity = ref.watch(localIdentityStateProvider);

    return Scaffold(
      backgroundColor: VantraTheme.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Scan QR Code'),
      ),
      body: peerProfileAsync.when(
        data: (peer) {
          if (peer == null) {
            return const Center(child: Text('Peer not found', style: TextStyle(color: VantraTheme.textPrimary)));
          }

          if (peer.publicKey == null || localIdentity.identityPublicKey.isEmpty) {
            return const Center(
              child: Text(
                'Cryptographic keys not exchanged yet.\nEstablish a connection first.',
                textAlign: TextAlign.center,
                style: TextStyle(color: VantraTheme.textSecondary),
              ),
            );
          }

          // Compute expected Safety Number locally
          final expectedSafetyNumber = SafetyNumberService.computeSafetyNumber(
            localIdentity.identityPublicKey,
            peer.publicKey!,
          );

          final matches = _scannedValue?.trim() == expectedSafetyNumber.trim();

          return Column(
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Text(
                  'Scan the QR code displayed on the other device. Vantra will verify if the safety numbers match.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: VantraTheme.textSecondary, fontSize: 14),
                ),
              ),
              
              // Scanner view
              Expanded(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.white12),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    children: [
                      if (_scannedValue == null)
                        MobileScanner(
                          controller: _scannerController,
                          onDetect: (capture) {
                            final List<Barcode> barcodes = capture.barcodes;
                            if (barcodes.isNotEmpty) {
                              final rawValue = barcodes.first.rawValue;
                              if (rawValue != null) {
                                setState(() {
                                  _scannedValue = rawValue;
                                });
                              }
                            }
                          },
                        )
                      else
                        Container(
                          color: VantraTheme.surface,
                          child: Center(
                            child: Icon(
                              matches ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded,
                              color: matches ? VantraTheme.greenVerified : VantraTheme.redBlocked,
                              size: 80,
                            ),
                          ),
                        ),
                      // Viewfinder overlay
                      if (_scannedValue == null)
                        Container(
                          decoration: ShapeDecoration(
                            shape: QrScannerOverlayShape(
                              borderColor: VantraTheme.primaryAccent,
                              borderRadius: 16,
                              borderLength: 30,
                              borderWidth: 6,
                              cutOutSize: 220,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              // Control panel / Results
              Padding(
                padding: const EdgeInsets.all(24.0),
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: VantraTheme.surface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_scannedValue == null) ...[
                        const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: VantraTheme.primaryAccent,
                              ),
                            ),
                            SizedBox(width: 12),
                            Text(
                              'Position QR code in the frame',
                              style: TextStyle(color: VantraTheme.textPrimary, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      ] else ...[
                        Text(
                          matches ? 'Verification Successful!' : 'Verification Failed!',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: matches ? VantraTheme.greenVerified : VantraTheme.redBlocked,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          matches
                              ? 'The Safety Number matches perfectly. You can now trust this device identity.'
                              : 'Safety Numbers mismatch! Scanned number does not match your locally calculated code. DO NOT verify.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: VantraTheme.textSecondary, fontSize: 13),
                        ),
                        const SizedBox(height: 16),
                        if (matches)
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: VantraTheme.greenVerified,
                              foregroundColor: Colors.white,
                              minimumSize: const Size(double.infinity, 48),
                            ),
                            onPressed: _isVerifying
                                ? null
                                : () async {
                                    final messenger = ScaffoldMessenger.of(context);
                                    final router = GoRouter.of(context);
                                    setState(() => _isVerifying = true);
                                    await ref
                                        .read(messagingStateProvider.notifier)
                                        .verifyPeer(peer.peerId, peer.publicKey!);
                                    if (mounted) {
                                      messenger.showSnackBar(
                                        SnackBar(content: Text('Identity verified for ${peer.effectiveName}!')),
                                      );
                                      router.pop();
                                    }
                                  },
                            child: _isVerifying
                                ? const CircularProgressIndicator(color: Colors.white)
                                : const Text('Mark Verified'),
                          ),
                        const SizedBox(height: 8),
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(double.infinity, 48),
                          ),
                          onPressed: () {
                            setState(() {
                              _scannedValue = null;
                            });
                          },
                          child: const Text('Scan Again'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator(color: VantraTheme.primary)),
        error: (err, _) => Center(child: Text('Error: $err', style: const TextStyle(color: VantraTheme.redBlocked))),
      ),
    );
  }
}

/// Custom scanner viewfinder overlay drawing path
class QrScannerOverlayShape extends ShapeBorder {
  final Color borderColor;
  final double borderWidth;
  final double borderLength;
  final double borderRadius;
  final double cutOutSize;

  const QrScannerOverlayShape({
    this.borderColor = Colors.white,
    this.borderWidth = 4.0,
    this.borderLength = 20.0,
    this.borderRadius = 8.0,
    this.cutOutSize = 200.0,
  });

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => Path();

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return Path()..addRect(rect);
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final width = rect.width;
    final height = rect.height;
    
    final cutOutRect = Rect.fromCenter(
      center: Offset(width / 2, height / 2),
      width: cutOutSize,
      height: cutOutSize,
    );

    // Draw dark transparent overlay
    final backgroundPaint = Paint()..color = Colors.black54;
    final backgroundPath = Path()
      ..addRect(rect)
      ..addRRect(RRect.fromRectAndRadius(cutOutRect, Radius.circular(borderRadius)))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(backgroundPath, backgroundPaint);

    // Draw borders/corners
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth;

    final borderPath = Path();
    
    // Top Left Corner
    borderPath.moveTo(cutOutRect.left, cutOutRect.top + borderLength);
    borderPath.lineTo(cutOutRect.left, cutOutRect.top);
    borderPath.lineTo(cutOutRect.left + borderLength, cutOutRect.top);

    // Top Right Corner
    borderPath.moveTo(cutOutRect.right - borderLength, cutOutRect.top);
    borderPath.lineTo(cutOutRect.right, cutOutRect.top);
    borderPath.lineTo(cutOutRect.right, cutOutRect.top + borderLength);

    // Bottom Left Corner
    borderPath.moveTo(cutOutRect.left, cutOutRect.bottom - borderLength);
    borderPath.lineTo(cutOutRect.left, cutOutRect.bottom);
    borderPath.lineTo(cutOutRect.left + borderLength, cutOutRect.bottom);

    // Bottom Right Corner
    borderPath.moveTo(cutOutRect.right - borderLength, cutOutRect.bottom);
    borderPath.lineTo(cutOutRect.right, cutOutRect.bottom);
    borderPath.lineTo(cutOutRect.right, cutOutRect.bottom - borderLength);

    canvas.drawPath(borderPath, borderPaint);
  }

  @override
  ShapeBorder scale(double t) => this;
}
