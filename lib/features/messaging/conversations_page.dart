import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vantra/core/models/conversation_summary.dart';
import 'package:vantra/core/models/message_status.dart';
import 'package:vantra/core/peers/peer_provider.dart';

class ConversationsPage extends ConsumerWidget {
  const ConversationsPage({super.key});

  String _formatTimestamp(int timestampMs) {
    final now = DateTime.now();
    final date = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final diff = now.difference(date);

    if (diff.inDays == 0) {
      final hour = date.hour.toString().padLeft(2, '0');
      final minute = date.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    } else if (diff.inDays == 1) {
      return 'Yesterday';
    } else if (diff.inDays < 7) {
      const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return weekdays[date.weekday - 1];
    } else {
      return '${date.day}/${date.month}';
    }
  }

  Widget _buildStatusIcon(MessageStatus status) {
    switch (status) {
      case MessageStatus.pending:
        return const Icon(Icons.access_time, size: 12, color: Colors.grey);
      case MessageStatus.failed:
        return const Icon(Icons.error_outline, size: 12, color: Colors.redAccent);
      case MessageStatus.sent:
        return const Icon(Icons.check, size: 12, color: Colors.grey);
      case MessageStatus.delivered:
        return const Icon(Icons.done_all, size: 13, color: Colors.cyanAccent);
      case MessageStatus.received:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summariesAsync = ref.watch(conversationSummariesStreamProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Conversations', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_outline),
            tooltip: 'My Profile',
            onPressed: () => context.push('/profile'),
          ),
        ],
      ),
      body: summariesAsync.when(
        data: (summaries) {
          if (summaries.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey.shade600),
                  const SizedBox(height: 16),
                  const Text(
                    'No conversations yet',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Discover nearby peers to start secure messaging',
                    style: TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: () => context.push('/nearby'),
                    icon: const Icon(Icons.radar),
                    label: const Text('Discover Nearby Devices'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.deepPurple,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    ),
                  ),
                ],
              ),
            );
          }

          return ListView.separated(
            itemCount: summaries.length,
            separatorBuilder: (context, index) => const Divider(height: 1, indent: 72, color: Colors.white10),
            itemBuilder: (context, index) {
              final summary = summaries[index];
              return _ConversationTile(
                summary: summary,
                formattedTime: _formatTimestamp(summary.lastMessageTimestamp),
                statusIcon: _buildStatusIcon(summary.lastMessageStatus),
                onTap: () => context.push('/chat/${summary.peerId}'),
                onLongPress: () => context.push('/peer/${summary.peerId}'),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(child: Text('Error: $err', style: const TextStyle(color: Colors.redAccent))),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/nearby'),
        backgroundColor: Colors.deepPurple,
        tooltip: 'Discover Nearby',
        child: const Icon(Icons.search, color: Colors.white),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  final ConversationSummary summary;
  final String formattedTime;
  final Widget statusIcon;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ConversationTile({
    required this.summary,
    required this.formattedTime,
    required this.statusIcon,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final hasUnread = summary.unreadCount > 0;

    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Stack(
        children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: summary.isTrusted
                ? Colors.green.shade800
                : summary.isBlocked
                    ? Colors.red.shade900
                    : Colors.deepPurple.shade700,
            child: Text(
              summary.effectiveName.isNotEmpty ? summary.effectiveName[0].toUpperCase() : '?',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ),
          if (summary.isOnline)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: Colors.greenAccent,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF121212), width: 2),
                ),
              ),
            ),
        ],
      ),
      title: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    summary.effectiveName,
                    style: TextStyle(
                      fontWeight: hasUnread ? FontWeight.bold : FontWeight.w600,
                      fontSize: 16,
                      color: summary.isBlocked ? Colors.grey : Colors.white,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (summary.isTrusted) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.verified, size: 15, color: Colors.greenAccent),
                ],
                if (summary.isBlocked) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.block, size: 15, color: Colors.redAccent),
                ],
              ],
            ),
          ),
          Text(
            formattedTime,
            style: TextStyle(
              fontSize: 12,
              color: hasUnread ? Colors.deepPurpleAccent : Colors.grey.shade400,
              fontWeight: hasUnread ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
      subtitle: Row(
        children: [
          if (summary.isOutgoing) ...[
            statusIcon,
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              summary.lastMessageText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                color: hasUnread ? Colors.white : Colors.grey.shade400,
                fontWeight: hasUnread ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          if (hasUnread)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.deepPurpleAccent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                summary.unreadCount.toString(),
                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ),
        ],
      ),
    );
  }
}
