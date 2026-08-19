import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/security/safety_number_service.dart';
import 'package:vantra/core/models/peer_profile.dart';
import 'package:vantra/core/models/peer_session.dart';
import 'package:vantra/core/models/peer_trust_state.dart';
import 'package:vantra/core/peers/peer_provider.dart';
import 'package:vantra/core/themes/vantra_theme.dart';

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
              style: TextStyle(fontSize: 13, color: VantraTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(color: VantraTheme.textPrimary),
              decoration: const InputDecoration(
                labelText: 'Nickname',
                hintText: 'e.g. Alice Work',
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
          style: const TextStyle(color: VantraTheme.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: VantraTheme.redBlocked, foregroundColor: Colors.white),
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

  void _showDeleteConfirmation(BuildContext context, WidgetRef ref, PeerProfile peer) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete contact?'),
        content: Text(
          'This will delete ${peer.effectiveName} from your contacts list along with all messaging and transfer history.',
          style: const TextStyle(color: VantraTheme.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: VantraTheme.redBlocked, foregroundColor: Colors.white),
            onPressed: () async {
              await ref.read(messagingStateProvider.notifier).deleteContact(peer.peerId);
              if (ctx.mounted) {
                Navigator.pop(ctx);
                Navigator.pop(context);
              }
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _showSafetyNumberSheet(BuildContext context, WidgetRef ref, PeerProfile peer) {
    final localIdentity = ref.read(localIdentityStateProvider);
    final expectedSafetyNumber = (peer.publicKey != null && localIdentity.identityPublicKey.isNotEmpty)
        ? SafetyNumberService.computeSafetyNumber(localIdentity.identityPublicKey, peer.publicKey!)
        : 'Keys not exchanged yet';

    showModalBottomSheet(
      context: context,
      backgroundColor: VantraTheme.surface,
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
                const Icon(Icons.security_rounded, color: VantraTheme.primaryAccent, size: 28),
                const SizedBox(width: 12),
                Text(
                  'Verify Identity',
                  style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold, color: VantraTheme.textPrimary),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Compare the Safety Number below in person with ${peer.effectiveName}, or scan each other\'s QR codes.',
              style: const TextStyle(fontSize: 14, color: VantraTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: VantraTheme.background,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: Center(
                child: SelectableText(
                  expectedSafetyNumber,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: VantraTheme.cyanSecurity,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: VantraTheme.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: peer.publicKey == null
                        ? null
                        : () {
                            Navigator.pop(ctx);
                            context.push('/peers/${peer.peerId}/verify');
                          },
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    label: const Text('Scan QR Code'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: VantraTheme.surface,
                      foregroundColor: VantraTheme.textPrimary,
                      side: const BorderSide(color: Colors.white12),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: peer.publicKey == null
                        ? null
                        : () {
                            Navigator.pop(ctx);
                            context.push('/peers/${peer.peerId}/my-qr');
                          },
                    icon: const Icon(Icons.qr_code_rounded),
                    label: const Text('Show My QR'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () async {
                  await ref.read(messagingStateProvider.notifier).setPeerTrustState(
                        peer.peerId,
                        PeerTrustState.trusted,
                      );
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('Mark Trusted Manually'),
              ),
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
        title: const Text('Peer Details'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_note_rounded),
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
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Avatar
                CircleAvatar(
                  radius: 48,
                  backgroundColor: peer.isTrusted
                      ? VantraTheme.greenVerified.withValues(alpha: 0.15)
                      : peer.isBlocked
                          ? VantraTheme.redBlocked.withValues(alpha: 0.15)
                          : VantraTheme.primary.withValues(alpha: 0.15),
                  child: Text(
                    peer.effectiveName.isNotEmpty ? peer.effectiveName[0].toUpperCase() : '?',
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                      color: peer.isTrusted
                          ? VantraTheme.greenVerified
                          : peer.isBlocked
                              ? VantraTheme.redBlocked
                              : VantraTheme.primaryAccent,
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Effective Name
                Text(
                  peer.effectiveName,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: VantraTheme.textPrimary),
                ),

                // Authenticated Device Name (if nickname exists)
                if (peer.nickname != null && peer.nickname!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Device Name: ${peer.displayName}',
                    style: const TextStyle(fontSize: 13, color: VantraTheme.textSecondary),
                  ),
                ],
                const SizedBox(height: 24),

                // Trust Badge Card (Redesigned visual certificate card)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: peer.isVerified
                        ? VantraTheme.greenVerified.withValues(alpha: 0.08)
                        : peer.isTrusted
                            ? VantraTheme.greenVerified.withValues(alpha: 0.04)
                            : peer.isBlocked
                                ? VantraTheme.redBlocked.withValues(alpha: 0.08)
                                : VantraTheme.amberWarning.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: peer.isVerified
                          ? VantraTheme.greenVerified
                          : peer.isTrusted
                              ? VantraTheme.greenVerified.withValues(alpha: 0.5)
                              : peer.isBlocked
                                  ? VantraTheme.redBlocked
                                  : VantraTheme.amberWarning,
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        peer.isVerified
                            ? Icons.verified_user_rounded
                            : peer.isTrusted
                                ? Icons.verified_user_outlined
                                : peer.isBlocked
                                    ? Icons.block_flipped
                                    : Icons.warning_amber_rounded,
                        color: peer.isVerified
                            ? VantraTheme.greenVerified
                            : peer.isTrusted
                                ? VantraTheme.greenVerified
                                : peer.isBlocked
                                    ? VantraTheme.redBlocked
                                    : VantraTheme.amberWarning,
                        size: 24,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              peer.isVerified
                                  ? 'Verified Identity'
                                  : peer.isTrusted
                                      ? 'Manually Trusted'
                                      : peer.isBlocked
                                          ? 'Blocked Peer'
                                          : 'Untrusted Identity',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14.5,
                                color: peer.isVerified
                                    ? VantraTheme.greenVerified
                                    : peer.isTrusted
                                        ? VantraTheme.greenVerified
                                        : peer.isBlocked
                                            ? VantraTheme.redBlocked
                                            : VantraTheme.amberWarning,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              peer.isVerified
                                  ? 'Identity verified via QR code scan'
                                  : peer.isTrusted
                                      ? 'Peer marked as trusted manually'
                                      : peer.isBlocked
                                          ? 'Cannot send or receive messages'
                                          : 'Compare Safety Number to prevent MITM attacks',
                              style: const TextStyle(fontSize: 12.5, color: VantraTheme.textSecondary),
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
                          icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16),
                          label: const Text('Open Chat'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: VantraTheme.primary,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _showSafetyNumberSheet(context, ref, peer),
                        icon: const Icon(Icons.fingerprint_rounded, size: 16),
                        label: const Text('Verify Identity'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // Collapsible Cryptographic Details Section
                Card(
                  child: Theme(
                    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      leading: const Icon(Icons.lock_person_rounded, color: VantraTheme.primaryAccent),
                      title: const Text(
                        'Security & Encryption details',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: VantraTheme.textPrimary),
                      ),
                      childrenPadding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
                      children: [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.wifi_rounded, color: Colors.blueAccent),
                          title: const Text('Connection Status', style: TextStyle(fontSize: 13.5)),
                          subtitle: Text(
                            isConnected
                                ? 'Securely Connected'
                                : isConnecting
                                    ? 'Connecting...'
                                    : 'Offline',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: isConnected ? VantraTheme.greenVerified : VantraTheme.textSecondary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const Divider(color: Colors.white10),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.history_toggle_off_rounded, color: Colors.purpleAccent),
                          title: const Text('Last Seen', style: TextStyle(fontSize: 13.5)),
                          subtitle: Text(_formatLastSeen(peer.lastSeen), style: const TextStyle(fontSize: 12.5)),
                        ),
                        const Divider(color: Colors.white10),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.fingerprint_rounded, color: VantraTheme.cyanSecurity),
                          title: const Text('Fingerprint (SHA-256)', style: TextStyle(fontSize: 13.5)),
                          subtitle: Text(
                            peer.fingerprint ?? 'Pending exchange',
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: VantraTheme.textSecondary),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.copy_all_rounded, size: 18),
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
                          icon: const Icon(Icons.lock_open_rounded, color: VantraTheme.greenVerified),
                          label: const Text('Unblock Peer', style: TextStyle(color: VantraTheme.greenVerified)),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: VantraTheme.greenVerified),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        )
                      : OutlinedButton.icon(
                          onPressed: () => _showBlockConfirmation(context, ref, peer),
                          icon: const Icon(Icons.block_flipped, color: VantraTheme.redBlocked),
                          label: const Text('Block Peer', style: TextStyle(color: VantraTheme.redBlocked)),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: VantraTheme.redBlocked),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _showDeleteConfirmation(context, ref, peer),
                    icon: const Icon(Icons.delete_forever_rounded, color: VantraTheme.redBlocked),
                    label: const Text('Delete Contact', style: TextStyle(color: VantraTheme.redBlocked)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: VantraTheme.redBlocked),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
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
