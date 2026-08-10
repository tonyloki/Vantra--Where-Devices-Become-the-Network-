import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/messaging/message.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/models/peer_session.dart';
import 'package:vantra/core/models/peer_trust_state.dart';
import 'package:vantra/core/models/message_status.dart';
import 'package:vantra/core/peers/peer_provider.dart';
import 'package:vantra/core/utils/logger.dart';

class ChatPage extends ConsumerStatefulWidget {
  final String peerId;

  const ChatPage({super.key, required this.peerId});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool? _wasBlocked;
  bool? _wasConnectedSecure;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(messagingStateProvider.notifier).setActiveConversation(widget.peerId);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      });
    }
  }

  String _formatTimestamp(int milliseconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Widget _buildStatusIcon(MessageStatus status) {
    switch (status) {
      case MessageStatus.pending:
        return const Icon(Icons.access_time, size: 10, color: Colors.white70);
      case MessageStatus.failed:
        return const Icon(Icons.error_outline, size: 10, color: Colors.redAccent);
      case MessageStatus.sent:
        return const Icon(Icons.check, size: 10, color: Colors.white70);
      case MessageStatus.delivered:
        return const Icon(Icons.done_all, size: 12, color: Colors.cyanAccent);
      case MessageStatus.received:
        return const Icon(Icons.check_circle_outline, size: 10, color: Colors.white70);
    }
  }

  @override
  Widget build(BuildContext context) {
    final localId = ref.watch(localIdentityStateProvider);
    final messagingState = ref.watch(messagingStateProvider);
    final peerProfileAsync = ref.watch(peerProfileStreamProvider(widget.peerId));

    final session = messagingState.sessions[widget.peerId];
    final messagesAsync = ref.watch(conversationStreamProvider(widget.peerId));

    ref.listen<AsyncValue<List<VantraMessage>>>(
      conversationStreamProvider(widget.peerId),
      (previous, next) {
        if (next.hasValue) {
          VantraLogger.log('[VANTRA][UI] CONVERSATION STREAM UPDATE peerId=${widget.peerId} messageCount=${next.value!.length}');
        }
      },
    );

    final peerProfile = peerProfileAsync.value;
    final displayName = peerProfile?.effectiveName ?? session?.displayName ?? 'Peer ${widget.peerId.length >= 6 ? widget.peerId.substring(0, 6) : widget.peerId}';
    final isConnected = session?.status == SessionStatus.connected;
    final isBlocked = peerProfile?.isBlocked ?? false;
    final isTrusted = peerProfile?.isTrusted ?? (session?.trustState == PeerTrustState.trusted);
    final isSecure = session?.isSecure == true;
    final isConnectedSecure = isConnected && isSecure;

    if (isBlocked && _wasBlocked != true) {
      VantraLogger.log('[VANTRA][CHAT] SEND BLOCKED reason=INPUT_DISABLED');
    } else if (!isBlocked && !isConnectedSecure && (_wasConnectedSecure != false || _wasBlocked == true)) {
      VantraLogger.log('[VANTRA][CHAT] SEND BLOCKED reason=NOT_SECURE');
    }
    _wasBlocked = isBlocked;
    _wasConnectedSecure = isConnectedSecure;

    // Trigger auto-scroll on new message
    _scrollToBottom();

    return Scaffold(
      appBar: AppBar(
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.deepPurple, Colors.indigo],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              isTrusted ? Icons.verified : Icons.shield_outlined,
              color: isTrusted ? Colors.greenAccent : Colors.amberAccent,
            ),
            tooltip: isTrusted ? 'Verified Contact' : 'Untrusted (Tap for Profile)',
            onPressed: () => context.push('/peer/${widget.peerId}'),
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'Peer Profile',
            onPressed: () => context.push('/peer/${widget.peerId}'),
          ),
        ],
        title: InkWell(
          onTap: () => context.push('/peer/${widget.peerId}'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                displayName,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: isBlocked
                          ? Colors.redAccent
                          : isConnected
                              ? Colors.greenAccent
                              : Colors.grey,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    isBlocked
                        ? 'Blocked'
                        : isConnected
                            ? (session?.isSecure == true ? 'Securely Connected' : 'Connected')
                            : 'Disconnected',
                    style: TextStyle(
                      fontSize: 12,
                      color: isBlocked
                          ? Colors.redAccent
                          : isConnected
                              ? Colors.greenAccent
                              : Colors.grey,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF121212), Color(0xFF1E1E1E)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Column(
          children: [
            if (isBlocked)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                color: Colors.red.shade900.withValues(alpha: 0.4),
                child: const Row(
                  children: [
                    Icon(Icons.block, color: Colors.redAccent, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This peer is blocked. Messages and connections are rejected.',
                        style: TextStyle(color: Colors.redAccent, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              )
            else if (!isConnected)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                color: Colors.amber.shade900.withValues(alpha: 0.25),
                child: const Row(
                  children: [
                    Icon(Icons.wifi_off, color: Colors.amberAccent, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Session offline. You will be able to send messages once in range.',
                        style: TextStyle(color: Colors.amberAccent, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: messagesAsync.when(
                loading: () => const Center(
                  child: CircularProgressIndicator(),
                ),
                error: (err, stack) => Center(
                  child: Text(
                    'Error loading history: $err',
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ),
                data: (messages) {
                  VantraLogger.log('[VANTRA][UI] CHAT RENDER peerId=${widget.peerId} messageCount=${messages.length}');
                  if (messages.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.chat_bubble_outline_rounded,
                            size: 64,
                            color: Colors.deepPurple.withValues(alpha: 0.5),
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'No messages yet',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'End-to-End Encrypted with ChaCha20-Poly1305',
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final msg = messages[index];
                      final isMe = msg.senderId == localId.peerId;

                      final bubble = Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.75,
                        ),
                        decoration: BoxDecoration(
                          gradient: isMe
                              ? const LinearGradient(
                                  colors: [Colors.deepPurple, Colors.indigoAccent],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                )
                              : const LinearGradient(
                                  colors: [Color(0xFF2C2C2E), Color(0xFF3A3A3C)],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(16),
                            topRight: const Radius.circular(16),
                            bottomLeft: isMe ? const Radius.circular(16) : const Radius.circular(2),
                            bottomRight: isMe ? const Radius.circular(2) : const Radius.circular(16),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.2),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                          children: [
                            Text(
                              msg.text,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _formatTimestamp(msg.timestamp),
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 10,
                                  ),
                                ),
                                if (isMe) ...[
                                  const SizedBox(width: 4),
                                  _buildStatusIcon(msg.status),
                                ],
                              ],
                            ),
                          ],
                        ),
                      );

                      if (isMe && msg.status == MessageStatus.failed) {
                        return Align(
                          alignment: Alignment.centerRight,
                          child: GestureDetector(
                            onTap: () {
                              ref.read(messagingStateProvider.notifier).retryMessage(msg.messageId, widget.peerId);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Retrying message...')),
                              );
                            },
                            child: bubble,
                          ),
                        );
                      }

                      return Align(
                        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                        child: bubble,
                      );
                    },
                  );
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.05))),
              ),
              child: SafeArea(
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF2C2C2E),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: TextField(
                          key: const Key('chat_input_field'),
                          controller: _controller,
                          enabled: isConnected && !isBlocked,
                          textCapitalization: TextCapitalization.sentences,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            hintText: isBlocked
                                ? 'Peer is blocked'
                                : isConnected
                                    ? 'Type an encrypted message...'
                                    : 'Disconnected',
                            hintStyle: const TextStyle(color: Colors.white38),
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      decoration: const BoxDecoration(
                        color: Colors.deepPurple,
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        key: const Key('chat_send_button'),
                        icon: Icon(
                          Icons.send_rounded,
                          color: (isConnected && !isBlocked) ? Colors.white : Colors.white30,
                        ),
                        onPressed: (isConnected && !isBlocked)
                            ? () {
                                final text = _controller.text.trim();
                                final statusName = session?.status.name ?? 'disconnected';
                                VantraLogger.log('[VANTRA][CHAT] SEND PRESSED peerId=${widget.peerId} textLength=${text.length} connectionStatus=$statusName');
                                if (text.isNotEmpty) {
                                  _controller.clear();
                                  ref.read(messagingStateProvider.notifier).sendTextMessage(widget.peerId, text);
                                }
                              }
                            : null,
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
