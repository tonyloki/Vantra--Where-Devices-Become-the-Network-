import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/models/peer_session.dart';
import 'package:vantra/core/models/peer_trust_state.dart';
import 'package:vantra/core/models/message_status.dart';

class ChatPage extends ConsumerStatefulWidget {
  final String peerId;

  const ChatPage({super.key, required this.peerId});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

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
      case MessageStatus.received:
        return const Icon(Icons.check_circle_outline, size: 10, color: Colors.white70);
    }
  }

  void _showSecurityDetails(PeerSession? session) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        final fingerprint = session?.fingerprint ?? 'Pending Exchange';
        final isTrusted = session?.trustState == PeerTrustState.trusted;
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    session?.isSecure == true ? Icons.lock : Icons.lock_open,
                    color: session?.isSecure == true ? Colors.greenAccent : Colors.amberAccent,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    session?.isSecure == true ? 'Encrypted Session' : 'Security Pending',
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text('Cryptographic Fingerprint (SHA-256):', style: TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 6),
              SelectableText(
                fingerprint,
                style: const TextStyle(color: Colors.greenAccent, fontSize: 12, fontFamily: 'monospace'),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('Trust State: ', style: TextStyle(color: Colors.white70)),
                  Text(
                    session?.trustState.name.toUpperCase() ?? 'UNTRUSTED',
                    style: TextStyle(
                      color: isTrusted ? Colors.greenAccent : Colors.orangeAccent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isTrusted ? Colors.orangeAccent : Colors.greenAccent,
                    foregroundColor: Colors.black,
                  ),
                  icon: Icon(isTrusted ? Icons.warning_amber : Icons.verified),
                  label: Text(isTrusted ? 'Mark as Untrusted' : 'Verify & Mark as Trusted'),
                  onPressed: () {
                    Navigator.pop(context);
                    final newState = isTrusted ? PeerTrustState.untrusted : PeerTrustState.trusted;
                    ref.read(messagingStateProvider.notifier).setPeerTrustState(widget.peerId, newState);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final localId = ref.watch(localIdentityStateProvider);
    final messagingState = ref.watch(messagingStateProvider);

    final session = messagingState.sessions[widget.peerId];
    final messagesAsync = ref.watch(conversationStreamProvider(widget.peerId));

    final displayName = session?.displayName ?? 'Peer ${widget.peerId.substring(0, 6)}';
    final isConnected = session?.status == SessionStatus.connected;

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
              session?.isSecure == true ? Icons.security : Icons.security_outlined,
              color: session?.trustState == PeerTrustState.trusted ? Colors.greenAccent : Colors.white70,
            ),
            tooltip: 'Security & Fingerprint',
            onPressed: () => _showSecurityDetails(session),
          ),
        ],
        title: Column(
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
                    color: isConnected ? Colors.greenAccent : Colors.redAccent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  isConnected ? (session?.isSecure == true ? 'Securely Connected' : 'Connected') : 'Disconnected',
                  style: TextStyle(
                    fontSize: 12,
                    color: isConnected ? Colors.greenAccent : Colors.redAccent,
                  ),
                ),
              ],
            ),
          ],
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
            if (!isConnected)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                color: Colors.redAccent.withValues(alpha: 0.2),
                child: const Row(
                  children: [
                    Icon(Icons.wifi_off, color: Colors.redAccent, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Session disconnected. Text messaging is disabled.',
                        style: TextStyle(color: Colors.redAccent, fontSize: 13),
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
                  if (messages.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.chat_bubble_outline_rounded,
                            size: 64,
                            color: Colors.grey.withValues(alpha: 0.3),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No messages yet',
                            style: TextStyle(color: Colors.grey.withValues(alpha: 0.6), fontSize: 16),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Type a message below to start chat',
                            style: TextStyle(color: Colors.grey.withValues(alpha: 0.4), fontSize: 12),
                          ),
                        ],
                      ),
                    );
                  }

                  return ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      final isMe = message.senderId == localId.peerId;

                      return Align(
                        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.75,
                          ),
                          decoration: BoxDecoration(
                            gradient: isMe
                                ? const LinearGradient(
                                    colors: [Colors.deepPurpleAccent, Colors.indigoAccent],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  )
                                : LinearGradient(
                                    colors: [Colors.grey[850]!, Colors.grey[900]!],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                            borderRadius: BorderRadius.only(
                              topLeft: const Radius.circular(16),
                              topRight: const Radius.circular(16),
                              bottomLeft: isMe ? const Radius.circular(16) : const Radius.circular(0),
                              bottomRight: isMe ? const Radius.circular(0) : const Radius.circular(16),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.2),
                                blurRadius: 4,
                                offset: const Offset(2, 2),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (!isMe)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Text(
                                    displayName,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.cyanAccent,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              Text(
                                message.text,
                                style: const TextStyle(color: Colors.white, fontSize: 15),
                              ),
                              const SizedBox(height: 4),
                              Align(
                                alignment: Alignment.bottomRight,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      _formatTimestamp(message.timestamp),
                                      style: TextStyle(
                                        color: Colors.white70.withValues(alpha: 0.6),
                                        fontSize: 10,
                                      ),
                                    ),
                                    if (isMe) ...[
                                      const SizedBox(width: 4),
                                      _buildStatusIcon(message.status),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.only(left: 16, right: 8, top: 8, bottom: 24),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                border: Border(
                  top: BorderSide(color: Colors.grey[900]!),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('chat_input_field'),
                      controller: _controller,
                      enabled: isConnected,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: isConnected ? 'Type a message...' : 'Connecting offline...',
                        hintStyle: const TextStyle(color: Colors.grey),
                        border: InputBorder.none,
                      ),
                      onSubmitted: isConnected ? (_) => _sendMessage() : null,
                    ),
                  ),
                  IconButton(
                    key: const Key('chat_send_button'),
                    icon: const Icon(Icons.send_rounded),
                    color: Colors.deepPurpleAccent,
                    disabledColor: Colors.grey,
                    onPressed: isConnected ? _sendMessage : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _sendMessage() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    _controller.clear();
    ref.read(messagingStateProvider.notifier).sendTextMessage(widget.peerId, text).catchError((e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Send failed: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    });
  }
}
