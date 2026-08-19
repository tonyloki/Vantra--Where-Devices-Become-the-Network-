import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/peers/peer_provider.dart';
import 'package:vantra/core/security/safety_number_service.dart';
import 'package:vantra/core/themes/vantra_theme.dart';

class ShowMyQrPage extends ConsumerWidget {
  final String peerId;

  const ShowMyQrPage({super.key, required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peerProfileAsync = ref.watch(peerProfileStreamProvider(peerId));
    final localIdentity = ref.watch(localIdentityStateProvider);

    return Scaffold(
      backgroundColor: VantraTheme.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('My QR Code'),
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
          final safetyNumber = SafetyNumberService.computeSafetyNumber(
            localIdentity.identityPublicKey,
            peer.publicKey!,
          );

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  'Let ${peer.effectiveName} scan this code',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: VantraTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'When scanned, this will confirm your identity on their device.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: VantraTheme.textSecondary, fontSize: 14),
                ),
                const SizedBox(height: 32),

                // QR Container
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: QrImageView(
                    data: safetyNumber,
                    version: QrVersions.auto,
                    size: 260.0,
                    gapless: false,
                    foregroundColor: const Color(0xFF0A0A0C),
                  ),
                ),
                const SizedBox(height: 32),

                // Safety Number Text Display
                const Text(
                  'Safety Number',
                  style: TextStyle(
                    fontSize: 13,
                    color: VantraTheme.textSecondary,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  safetyNumber,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: VantraTheme.cyanSecurity,
                    letterSpacing: 2.0,
                  ),
                ),
                const SizedBox(height: 48),

                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: VantraTheme.primary,
                    minimumSize: const Size(double.infinity, 50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: () => context.pop(),
                  child: const Text('Done'),
                ),
              ],
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator(color: VantraTheme.primary)),
        error: (err, _) => Center(child: Text('Error: $err', style: const TextStyle(color: VantraTheme.redBlocked))),
      ),
    );
  }
}
