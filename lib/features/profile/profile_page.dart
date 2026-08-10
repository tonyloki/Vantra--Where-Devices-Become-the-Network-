import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/themes/vantra_theme.dart';

class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  void _showEditNameDialog(BuildContext context, WidgetRef ref, String currentName) {
    final controller = TextEditingController(text: currentName);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change Device Name'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This is your authenticated display name broadcasted to other nearby devices during identity handshake.',
              style: TextStyle(fontSize: 13, color: VantraTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(color: VantraTheme.textPrimary),
              decoration: const InputDecoration(
                labelText: 'Display Name',
                hintText: 'e.g. Tony-Pixel',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newName = controller.text.trim();
              if (newName.isNotEmpty) {
                await ref.read(localIdentityStateProvider.notifier).updateDisplayName(newName);
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localIdentity = ref.watch(localIdentityStateProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Local Avatar
            CircleAvatar(
              radius: 48,
              backgroundColor: VantraTheme.primary.withValues(alpha: 0.15),
              child: Text(
                localIdentity.displayName.isNotEmpty ? localIdentity.displayName[0].toUpperCase() : 'V',
                style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: VantraTheme.primaryAccent),
              ),
            ),
            const SizedBox(height: 16),

            // Display Name with edit button
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(width: 32), // Balance out the edit icon spacing
                Text(
                  localIdentity.displayName,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: VantraTheme.textPrimary),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.edit_note_rounded, size: 24, color: VantraTheme.primaryAccent),
                  tooltip: 'Edit Display Name',
                  onPressed: () => _showEditNameDialog(context, ref, localIdentity.displayName),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: VantraTheme.greenVerified.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: VantraTheme.greenVerified.withValues(alpha: 0.5)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.shield_rounded, size: 14, color: VantraTheme.greenVerified),
                  SizedBox(width: 6),
                  Text(
                    'Ed25519 Keystore Protected',
                    style: TextStyle(fontSize: 12, color: VantraTheme.greenVerified, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),

            // Settings Section: Cryptographic Identity Cards
            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(left: 4, bottom: 8),
                child: Text(
                  'CRYPTOGRAPHIC CREDENTIALS',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: VantraTheme.textMuted, letterSpacing: 1),
                ),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.badge_outlined, color: Colors.blueAccent),
                      title: const Text('Persistent Peer ID', style: TextStyle(fontSize: 14, color: VantraTheme.textPrimary)),
                      subtitle: SelectableText(
                        localIdentity.peerId,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: VantraTheme.textSecondary),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.copy_all_rounded, size: 18),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: localIdentity.peerId));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Peer ID copied to clipboard')),
                          );
                        },
                      ),
                    ),
                    const Divider(color: Colors.white10),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.fingerprint_rounded, color: VantraTheme.cyanSecurity),
                      title: const Text('Security Fingerprint', style: TextStyle(fontSize: 14, color: VantraTheme.textPrimary)),
                      subtitle: SelectableText(
                        localIdentity.fingerprint.isNotEmpty ? localIdentity.fingerprint : 'Generating...',
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: VantraTheme.cyanSecurity),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.copy_all_rounded, size: 18),
                        onPressed: localIdentity.fingerprint.isNotEmpty
                            ? () {
                                Clipboard.setData(ClipboardData(text: localIdentity.fingerprint));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Fingerprint copied to clipboard')),
                                );
                              }
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 32),

            // Separator & Developer Section
            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(left: 4, bottom: 8),
                child: Text(
                  'DEVELOPER PORTAL',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: VantraTheme.textMuted, letterSpacing: 1),
                ),
              ),
            ),
            Card(
              color: VantraTheme.surfaceElevated.withValues(alpha: 0.2),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: VantraTheme.primary, width: 0.5),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Technical Diagnostics',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: VantraTheme.textPrimary),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Access the transport proof-of-concept, test network discovery manually, and read live connection logs.',
                      style: TextStyle(fontSize: 12.5, color: VantraTheme.textSecondary, height: 1.4),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () => context.push('/poc'),
                        icon: const Icon(Icons.developer_board_rounded, size: 18),
                        label: const Text('Launch Debug POC & Logs'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: VantraTheme.primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
