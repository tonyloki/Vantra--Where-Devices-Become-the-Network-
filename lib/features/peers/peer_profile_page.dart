import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/models/peer_profile.dart';
import 'package:vantra/core/models/peer_session.dart';
import 'package:vantra/core/models/peer_trust_state.dart';
import 'package:vantra/core/peers/peer_provider.dart';

class PeerProfilePage extends ConsumerWidget {
  final String peerId;

  const PeerProfilePage({super.key, required this.peerId});

  String _formatLastSeen(int timestampMs) {
    if (timestampMs == 0) return 'Never';
    final date = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inMinutes < 5) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes} minutes ago';
    if (diff.inDays == 0) return 'Today at ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    if (diff.inDays == 1) return 'Yesterday';
    return '${date.day}/${date.month}/${date.year}';
  }

  void _showRenameDialog(BuildContext context, WidgetRef ref, PeerProfile peer) {
    final controller = TextEditingController(text: peer.nickname ?? '');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set Local Nickname'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This nickname is stored only on your device and will never be shared with others.',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Nickname',
                hintText: 'e.g. Alice Work',
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
              final newNick = controller.text.trim();
              await ref.read(messagingStateProvider.notifier).updatePeerNickname(
                    peer.peerId,
                    newNick.isNotEmpty ? newNick : null,
                  );
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showBlockConfirmation(BuildContext context, WidgetRef ref, PeerProfile peer) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Block this peer?'),
        content: Text(
          'You will no longer receive messages or connections from ${peer.effectiveName}.\n\nExisting conversation history will be preserved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            onPressed: () async {
              await ref.read(messagingStateProvider.notifier).blockPeer(peer.peerId);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Block'),
          ),
        ],
      ),
    );
  }

  void _showFingerprintVerificationSheet(BuildContext context, WidgetRef ref, PeerProfile peer) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.security, color: Colors.deepPurpleAccent, size: 28),
                const SizedBox(width: 12),
                Text(
                  'Verify Security Fingerprint',
                  style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Compare this fingerprint in person or through another trusted channel with ${peer.effectiveName}:',
              style: const TextStyle(fontSize: 14, color: Colors.white70),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF121212),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: SelectableText(
                peer.fingerprint ?? 'No cryptographic key exchanged yet',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.greenAccent,
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Only mark this device as trusted after comparing the fingerprint through another trusted channel.',
              style: TextStyle(fontSize: 12, color: Colors.amberAccent),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      await ref.read(messagingStateProvider.notifier).setPeerTrustState(
                            peer.peerId,
                            PeerTrustState.untrusted,
                          );
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    child: const Text('Mark Untrusted'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade700,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () async {
                      await ref.read(messagingStateProvider.notifier).setPeerTrustState(
                            peer.peerId,
                            PeerTrustState.trusted,
                          );
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    icon: const Icon(Icons.verified),
                    label: const Text('Mark as Trusted'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peerProfileAsync = ref.watch(peerProfileStreamProvider(peerId));
    final messagingState = ref.watch(messagingStateProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Peer Profile'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Set Local Nickname',
            onPressed: () {
              final peer = peerProfileAsync.value;
              if (peer != null) _showRenameDialog(context, ref, peer);
            },
          ),
        ],
      ),
      body: peerProfileAsync.when(
        data: (peer) {
          if (peer == null) {
            return const Center(child: Text('Peer not found in database.'));
          }

          final session = messagingState.sessions[peer.peerId];
          final isConnected = session?.status == SessionStatus.connected;
          final isConnecting = session?.status == SessionStatus.connecting || session?.status == SessionStatus.handshaking;

          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Avatar
                CircleAvatar(
                  radius: 48,
                  backgroundColor: peer.isTrusted
                      ? Colors.green.shade800
                      : peer.isBlocked
                          ? Colors.red.shade900
                          : Colors.deepPurple.shade700,
                  child: Text(
                    peer.effectiveName.isNotEmpty ? peer.effectiveName[0].toUpperCase() : '?',
                    style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                ),
                const SizedBox(height: 16),

                // Effective Name
                Text(
                  peer.effectiveName,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),

                // Authenticated Device Name (if nickname exists)
                if (peer.nickname != null && peer.nickname!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Device Name: ${peer.displayName}',
                    style: const TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                ],
                const SizedBox(height: 16),

                // Trust Badge Card
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: peer.isTrusted
                        ? Colors.green.shade900.withValues(alpha: 0.3)
                        : peer.isBlocked
                            ? Colors.red.shade900.withValues(alpha: 0.3)
                            : Colors.amber.shade900.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: peer.isTrusted
                          ? Colors.greenAccent
                          : peer.isBlocked
                              ? Colors.redAccent
                              : Colors.amberAccent,
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        peer.isTrusted
                            ? Icons.verified
                            : peer.isBlocked
                                ? Icons.block
                                : Icons.warning_amber_rounded,
                        color: peer.isTrusted
                            ? Colors.greenAccent
                            : peer.isBlocked
                                ? Colors.redAccent
                                : Colors.amberAccent,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              peer.isTrusted
                                  ? 'Verified Trusted Contact'
                                  : peer.isBlocked
                                      ? 'Blocked Peer'
                                      : 'Untrusted Identity',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: peer.isTrusted
                                    ? Colors.greenAccent
                                    : peer.isBlocked
                                        ? Colors.redAccent
                                        : Colors.amberAccent,
                              ),
                            ),
                            Text(
                              peer.isTrusted
                                  ? 'Fingerprint verified in-person'
                                  : peer.isBlocked
                                      ? 'Cannot send or receive messages'
                                      : 'Compare fingerprint to verify',
                              style: const TextStyle(fontSize: 12, color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Action Buttons
                Row(
                  children: [
                    if (!peer.isBlocked) ...[
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () => context.push('/chat/${peer.peerId}'),
                          icon: const Icon(Icons.chat),
                          label: const Text('Open Chat'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.deepPurple,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _showFingerprintVerificationSheet(context, ref, peer),
                        icon: const Icon(Icons.fingerprint),
                        label: const Text('Verify'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // Details Card
                Card(
                  color: const Color(0xFF1E1E1E),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.wifi, color: Colors.blueAccent),
                          title: const Text('Connection Status'),
                          subtitle: Text(
                            isConnected
                                ? 'Securely Connected'
                                : isConnecting
                                    ? 'Connecting...'
                                    : 'Offline',
                            style: TextStyle(
                              color: isConnected ? Colors.greenAccent : Colors.grey,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const Divider(color: Colors.white10),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.history, color: Colors.purpleAccent),
                          title: const Text('Last Seen'),
                          subtitle: Text(_formatLastSeen(peer.lastSeen)),
                        ),
                        const Divider(color: Colors.white10),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.fingerprint, color: Colors.tealAccent),
                          title: const Text('Fingerprint (SHA-256)'),
                          subtitle: Text(
                            peer.fingerprint ?? 'Pending exchange',
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.copy, size: 18),
                            onPressed: peer.fingerprint != null
                                ? () {
                                    Clipboard.setData(ClipboardData(text: peer.fingerprint!));
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

                // Block / Unblock Button
                SizedBox(
                  width: double.infinity,
                  child: peer.isBlocked
                      ? OutlinedButton.icon(
                          onPressed: () => ref.read(messagingStateProvider.notifier).unblockPeer(peer.peerId),
                          icon: const Icon(Icons.lock_open, color: Colors.greenAccent),
                          label: const Text('Unblock Peer', style: TextStyle(color: Colors.greenAccent)),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.greenAccent),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        )
                      : OutlinedButton.icon(
                          onPressed: () => _showBlockConfirmation(context, ref, peer),
                          icon: const Icon(Icons.block, color: Colors.redAccent),
                          label: const Text('Block Peer', style: TextStyle(color: Colors.redAccent)),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.redAccent),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                ),
              ],
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(child: Text('Error: $err', style: const TextStyle(color: Colors.redAccent))),
      ),
    );
  }
}
