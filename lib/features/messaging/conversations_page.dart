import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vantra/core/models/conversation_summary.dart';
import 'package:vantra/core/models/message_status.dart';
import 'package:vantra/core/networking/nearby_connection_service.dart';
import 'package:vantra/core/peers/peer_provider.dart';
import 'package:vantra/core/themes/vantra_theme.dart';

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
        return const Icon(Icons.access_time_rounded, size: 13, color: VantraTheme.textMuted);
      case MessageStatus.failed:
        return const Icon(Icons.error_outline_rounded, size: 13, color: VantraTheme.redBlocked);
      case MessageStatus.sent:
        return const Icon(Icons.check_rounded, size: 13, color: VantraTheme.textSecondary);
      case MessageStatus.delivered:
        return const Icon(Icons.done_all_rounded, size: 14, color: VantraTheme.cyanSecurity);
      case MessageStatus.received:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summariesAsync = ref.watch(conversationSummariesStreamProvider);
    final connectionState = ref.watch(nearbyConnectionServiceProvider);
    final isScanning = connectionState.isAdvertising || connectionState.isDiscovering;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('VANTRA'),
            const SizedBox(width: 8),
            _StatusDot(active: isScanning),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_outline_rounded),
            tooltip: 'My Profile',
            onPressed: () => context.push('/profile'),
          ),
        ],
      ),
      body: summariesAsync.when(
        data: (summaries) {
          if (summaries.isEmpty) {
            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24.0),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.forum_outlined,
                          size: 64,
                          color: VantraTheme.primary.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 24),
                        const Text(
                          'No conversations yet',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: VantraTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Vantra is an offline-first private messaging app. Find other devices nearby using local p2p connections.',
                          style: TextStyle(
                            fontSize: 13,
                            color: VantraTheme.textSecondary,
                            height: 1.4,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          onPressed: () => context.push('/nearby'),
                          icon: const Icon(Icons.radar_rounded),
                          label: const Text('Discover Nearby'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.only(top: 8, bottom: 8),
            itemCount: summaries.length,
            separatorBuilder: (context, index) => const Divider(
              height: 1,
              indent: 76,
              color: Colors.white10,
            ),
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
        loading: () => const Center(child: CircularProgressIndicator(color: VantraTheme.primary)),
        error: (err, _) => Center(
          child: Text(
            'Error: $err',
            style: const TextStyle(color: VantraTheme.redBlocked),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/nearby'),
        backgroundColor: VantraTheme.primary,
        tooltip: 'Discover Nearby',
        child: const Icon(Icons.radar_rounded, color: Colors.white),
      ),
    );
  }
}

class _StatusDot extends StatefulWidget {
  final bool active;
  const _StatusDot({required this.active});

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) {
      return Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: VantraTheme.textMuted,
          shape: BoxShape.circle,
        ),
      );
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Opacity(
          opacity: 0.4 + (_controller.value * 0.6),
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: VantraTheme.greenVerified,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: VantraTheme.greenVerified.withValues(alpha: _controller.value),
                  blurRadius: 4,
                  spreadRadius: 1.5,
                ),
              ],
            ),
          ),
        );
      },
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

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Stack(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: summary.isTrusted
                      ? VantraTheme.greenVerified.withValues(alpha: 0.15)
                      : summary.isBlocked
                          ? VantraTheme.redBlocked.withValues(alpha: 0.15)
                          : VantraTheme.primary.withValues(alpha: 0.15),
                  child: Text(
                    summary.effectiveName.isNotEmpty ? summary.effectiveName[0].toUpperCase() : '?',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: summary.isTrusted
                          ? VantraTheme.greenVerified
                          : summary.isBlocked
                              ? VantraTheme.redBlocked
                              : VantraTheme.primaryAccent,
                    ),
                  ),
                ),
                if (summary.isOnline)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 13,
                      height: 13,
                      decoration: BoxDecoration(
                        color: VantraTheme.greenVerified,
                        shape: BoxShape.circle,
                        border: Border.all(color: VantraTheme.background, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                summary.effectiveName,
                                style: TextStyle(
                                  fontWeight: hasUnread ? FontWeight.bold : FontWeight.w600,
                                  fontSize: 15.5,
                                  color: summary.isBlocked ? VantraTheme.textMuted : VantraTheme.textPrimary,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (summary.isTrusted) ...[
                              const SizedBox(width: 5),
                              const Icon(Icons.verified_rounded, size: 15, color: VantraTheme.greenVerified),
                            ],
                            if (summary.isBlocked) ...[
                              const SizedBox(width: 5),
                              const Icon(Icons.block_flipped, size: 15, color: VantraTheme.redBlocked),
                            ],
                          ],
                        ),
                      ),
                      Text(
                        formattedTime,
                        style: TextStyle(
                          fontSize: 12,
                          color: hasUnread ? VantraTheme.primaryAccent : VantraTheme.textMuted,
                          fontWeight: hasUnread ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
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
                            fontSize: 13.5,
                            color: hasUnread ? VantraTheme.textPrimary : VantraTheme.textSecondary,
                            fontWeight: hasUnread ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      ),
                      if (hasUnread) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                          decoration: BoxDecoration(
                            color: VantraTheme.primary,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            summary.unreadCount.toString(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
