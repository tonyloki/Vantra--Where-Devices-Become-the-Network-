import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';

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
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Display Name',
                hintText: 'e.g. Tony-Pixel',
                border: OutlineInputBorder(),
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
        title: const Text('Device Profile & Identity', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Local Avatar
            CircleAvatar(
              radius: 48,
              backgroundColor: Colors.deepPurple.shade700,
              child: Text(
                localIdentity.displayName.isNotEmpty ? localIdentity.displayName[0].toUpperCase() : 'V',
                style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
            const SizedBox(height: 16),

            // Display Name with edit button
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  localIdentity.displayName,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.edit, size: 20),
                  tooltip: 'Edit Display Name',
                  onPressed: () => _showEditNameDialog(context, ref, localIdentity.displayName),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.green.shade900.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.greenAccent),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.shield, size: 14, color: Colors.greenAccent),
                  SizedBox(width: 6),
                  Text(
                    'Ed25519 Keystore Secured',
                    style: TextStyle(fontSize: 12, color: Colors.greenAccent, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Cryptographic Details
            Card(
              color: const Color(0xFF1E1E1E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.badge_outlined, color: Colors.blueAccent),
                      title: const Text('Persistent Peer ID'),
                      subtitle: SelectableText(
                        localIdentity.peerId,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.copy, size: 18),
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
                      leading: const Icon(Icons.fingerprint, color: Colors.tealAccent),
                      title: const Text('My Security Fingerprint (SHA-256)'),
                      subtitle: SelectableText(
                        localIdentity.fingerprint.isNotEmpty ? localIdentity.fingerprint : 'Generating...',
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.greenAccent),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.copy, size: 18),
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
            const SizedBox(height: 24),

            // Developer / Diagnostic Link
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => context.push('/poc'),
                icon: const Icon(Icons.developer_mode, color: Colors.deepPurpleAccent),
                label: const Text('Launch Transport POC & Debug Logs', style: TextStyle(color: Colors.deepPurpleAccent)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.deepPurpleAccent),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
