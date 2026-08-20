import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/messaging/message.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/peers/peer_provider.dart';
import 'package:vantra/core/themes/vantra_theme.dart';

class GroupChatPage extends ConsumerStatefulWidget {
  final String groupId;

  const GroupChatPage({
    super.key,
    required this.groupId,
  });

  @override
  ConsumerState<GroupChatPage> createState() => _GroupChatPageState();
}

class _GroupChatPageState extends ConsumerState<GroupChatPage> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _textController.dispose();
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

  void _sendMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    ref.read(messagingStateProvider.notifier).sendGroupMessage(
      widget.groupId,
      text,
    );
    _textController.clear();
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final localIdentity = ref.watch(localIdentityStateProvider);
    final groupAsync = ref.watch(groupsStreamProvider);
    final messagesAsync = ref.watch(groupConversationStreamProvider(widget.groupId));
    final membersAsync = ref.watch(groupMembersProvider(widget.groupId));

    // Find current group details
    final group = groupAsync.value?.firstWhere(
      (g) => g.groupId == widget.groupId,
      orElse: () => null as dynamic,
    );

    final groupName = group?.name ?? 'Group Chat';
    final memberCount = membersAsync.value?.length ?? 0;

    // Trigger auto-scroll on new message
    ref.listen(groupConversationStreamProvider(widget.groupId), (prev, next) {
      _scrollToBottom();
    });

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              groupName,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 2),
            Text(
              memberCount > 0 ? '$memberCount members' : 'Loading members...',
              style: const TextStyle(fontSize: 11, color: VantraTheme.textMuted),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          // Message List
          Expanded(
            child: messagesAsync.when(
              data: (messages) {
                if (messages.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.group_outlined,
                          size: 64,
                          color: VantraTheme.primary.withValues(alpha: 0.4),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Welcome to the group!',
                          style: TextStyle(
                            color: VantraTheme.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Pairwise Encrypted End-to-End',
                          style: TextStyle(
                            color: VantraTheme.textMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
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
                    final msg = messages[index];
                    final isMe = msg.senderId == localIdentity.peerId;

                    return Column(
                      crossAxisAlignment:
                          isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                      children: [
                        // Display sender's name if message is from another member
                        if (!isMe)
                          Padding(
                            padding: const EdgeInsets.only(left: 12.0, top: 8.0, bottom: 2.0),
                            child: Consumer(
                              builder: (ctx, ref, child) {
                                final profileAsync =
                                    ref.watch(peerProfileStreamProvider(msg.senderId));
                                final senderName = profileAsync.value?.effectiveName ??
                                    (msg.senderId.length >= 6
                                        ? 'Peer ${msg.senderId.substring(0, 6)}'
                                        : msg.senderId);
                                return Text(
                                  senderName,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: VantraTheme.primaryAccent,
                                    fontWeight: FontWeight.bold,
                                  ),
                                );
                              },
                            ),
                          ),

                        // Message Bubble
                        Row(
                          mainAxisAlignment:
                              isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                          children: [
                            Container(
                              margin: const EdgeInsets.symmetric(vertical: 2),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              constraints: BoxConstraints(
                                maxWidth: MediaQuery.of(context).size.width * 0.75,
                              ),
                              decoration: BoxDecoration(
                                gradient: isMe
                                    ? const LinearGradient(
                                        colors: [VantraTheme.primary, VantraTheme.secondary],
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                      )
                                    : null,
                                color: isMe ? null : VantraTheme.surface,
                                borderRadius: BorderRadius.only(
                                  topLeft: const Radius.circular(16),
                                  topRight: const Radius.circular(16),
                                  bottomLeft: Radius.circular(isMe ? 16 : 0),
                                  bottomRight: Radius.circular(isMe ? 0 : 16),
                                ),
                              ),
                              child: Text(
                                msg.text,
                                style: TextStyle(
                                  color: isMe ? Colors.white : VantraTheme.textPrimary,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                );
              },
              loading: () => const Center(
                child: CircularProgressIndicator(color: VantraTheme.primary),
              ),
              error: (err, _) => Center(
                child: Text('Error loading messages: $err',
                    style: const TextStyle(color: VantraTheme.redBlocked)),
              ),
            ),
          ),

          // Message Input Bar
          Container(
            padding: const EdgeInsets.only(left: 12, right: 12, bottom: 12, top: 4),
            decoration: const BoxDecoration(
              color: Colors.black,
              border: Border(top: BorderSide(color: Colors.white10, width: 0.5)),
            ),
            child: SafeArea(
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: VantraTheme.surface,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: TextField(
                        controller: _textController,
                        maxLines: null,
                        style: const TextStyle(color: VantraTheme.textPrimary),
                        decoration: const InputDecoration(
                          hintText: 'Type a group message...',
                          hintStyle: TextStyle(color: VantraTheme.textMuted),
                          contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _sendMessage,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: VantraTheme.primaryAccent,
                      ),
                      child: const Icon(
                        Icons.send_rounded,
                        color: Colors.black,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
