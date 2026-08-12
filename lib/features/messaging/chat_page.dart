import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/messaging/message.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/models/peer_session.dart';
import 'package:vantra/core/models/peer_trust_state.dart';
import 'package:vantra/core/models/message_status.dart';
import 'package:vantra/core/peers/peer_provider.dart';
import 'package:vantra/core/themes/vantra_theme.dart';
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

  Future<void> _pickAndPreviewImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (pickedFile == null) return;

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final captionController = TextEditingController();
        return AlertDialog(
          backgroundColor: VantraTheme.surface,
          title: const Text('Send Image', style: TextStyle(color: VantraTheme.textPrimary, fontWeight: FontWeight.bold)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(
                    File(pickedFile.path),
                    height: 250,
                    fit: BoxFit.contain,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: captionController,
                  style: const TextStyle(color: VantraTheme.textPrimary),
                  decoration: const InputDecoration(
                    hintText: 'Add a caption...',
                    hintStyle: TextStyle(color: VantraTheme.textMuted),
                    border: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel', style: TextStyle(color: VantraTheme.textMuted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: VantraTheme.primary),
              onPressed: () {
                final caption = captionController.text.trim();
                Navigator.of(ctx).pop();
                ref.read(messagingStateProvider.notifier).sendImageMessage(
                  widget.peerId,
                  pickedFile.path,
                  caption: caption.isNotEmpty ? caption : null,
                );
              },
              child: const Text('Send', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _pickAndPreviewFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;

    final picked = result.files.first;
    if (picked.path == null) {
      VantraLogger.log('[VANTRA][UI] File path is null for picked file: ${picked.name}');
      return;
    }

    final sizeLimit = 200 * 1024 * 1024;
    if (picked.size > sizeLimit) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('File exceeds 200 MB safety limit.'),
          backgroundColor: VantraTheme.redBlocked,
        ),
      );
      return;
    }

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final captionController = TextEditingController();
        return AlertDialog(
          backgroundColor: VantraTheme.surface,
          title: const Text('Send File', style: TextStyle(color: VantraTheme.textPrimary, fontWeight: FontWeight.bold)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.insert_drive_file_rounded, size: 64, color: VantraTheme.primary),
                const SizedBox(height: 12),
                Text(
                  picked.name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: VantraTheme.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 4),
                Text(
                  picked.size / 1024 > 1024
                      ? '${(picked.size / (1024 * 1024)).toStringAsFixed(1)} MB'
                      : '${(picked.size / 1024).toStringAsFixed(1)} KB',
                  style: const TextStyle(color: VantraTheme.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: captionController,
                  style: const TextStyle(color: VantraTheme.textPrimary),
                  decoration: const InputDecoration(
                    hintText: 'Add a caption...',
                    hintStyle: TextStyle(color: VantraTheme.textMuted),
                    border: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel', style: TextStyle(color: VantraTheme.textMuted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: VantraTheme.primary),
              onPressed: () {
                final caption = captionController.text.trim();
                Navigator.of(ctx).pop();
                ref.read(messagingStateProvider.notifier).sendFileMessage(
                  widget.peerId,
                  picked.path!,
                  caption: caption.isNotEmpty ? caption : null,
                );
              },
              child: const Text('Send', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _showFullscreenImage(String path) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.9),
      builder: (ctx) => GestureDetector(
        onTap: () => Navigator.of(ctx).pop(),
        child: InteractiveViewer(
          child: Center(
            child: Image.file(File(path)),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusIcon(MessageStatus status) {
    switch (status) {
      case MessageStatus.pending:
        return const Icon(Icons.access_time_rounded, size: 10, color: Colors.white70);
      case MessageStatus.sending:
        return const Icon(Icons.access_time_rounded, size: 10, color: Colors.white70);
      case MessageStatus.failed:
        return const Icon(Icons.error_outline_rounded, size: 11, color: VantraTheme.redBlocked);
      case MessageStatus.sent:
        return const Icon(Icons.check_rounded, size: 11, color: Colors.white70);
      case MessageStatus.delivered:
        return const Icon(Icons.done_all_rounded, size: 13, color: VantraTheme.cyanSecurity);
      case MessageStatus.received:
        return const Icon(Icons.check_circle_outline_rounded, size: 10, color: Colors.white70);
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
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.pop(),
        ),
        title: InkWell(
          onTap: () => context.push('/peer/${widget.peerId}'),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: isTrusted
                    ? VantraTheme.greenVerified.withValues(alpha: 0.15)
                    : isBlocked
                        ? VantraTheme.redBlocked.withValues(alpha: 0.15)
                        : VantraTheme.primary.withValues(alpha: 0.15),
                child: Text(
                  displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: isTrusted
                        ? VantraTheme.greenVerified
                        : isBlocked
                            ? VantraTheme.redBlocked
                            : VantraTheme.primaryAccent,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: isBlocked
                                ? VantraTheme.redBlocked
                                : isConnected
                                    ? VantraTheme.greenVerified
                                    : VantraTheme.textMuted,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isBlocked
                              ? 'Blocked'
                              : isConnected
                                  ? (session?.isSecure == true ? 'Securely Connected' : 'Connected')
                                  : 'Disconnected',
                          style: TextStyle(
                            fontSize: 11,
                            color: isBlocked
                                ? VantraTheme.redBlocked
                                : isConnected
                                    ? VantraTheme.greenVerified
                                    : VantraTheme.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              isTrusted ? Icons.verified_rounded : Icons.shield_outlined,
              color: isTrusted ? VantraTheme.greenVerified : VantraTheme.amberWarning,
            ),
            tooltip: isTrusted ? 'Verified Contact' : 'Untrusted (Tap to verify)',
            onPressed: () => context.push('/peer/${widget.peerId}'),
          ),
          IconButton(
            icon: const Icon(Icons.info_outline_rounded),
            tooltip: 'Peer Profile',
            onPressed: () => context.push('/peer/${widget.peerId}'),
          ),
        ],
      ),
      body: Container(
        color: VantraTheme.background,
        child: Column(
          children: [
            if (isBlocked)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                color: VantraTheme.redBlocked.withValues(alpha: 0.15),
                child: const Row(
                  children: [
                    Icon(Icons.block_flipped, color: VantraTheme.redBlocked, size: 20),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'This peer is blocked. Messages and connections are rejected.',
                        style: TextStyle(color: VantraTheme.redBlocked, fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              )
            else if (!isConnected)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                color: VantraTheme.amberWarning.withValues(alpha: 0.1),
                child: const Row(
                  children: [
                    Icon(Icons.wifi_off_rounded, color: VantraTheme.amberWarning, size: 20),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Session offline. Outgoing messages will queue and send once in range.',
                        style: TextStyle(color: VantraTheme.amberWarning, fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: messagesAsync.when(
                loading: () => const Center(
                  child: CircularProgressIndicator(color: VantraTheme.primary),
                ),
                error: (err, stack) => Center(
                  child: Text(
                    'Error loading history: $err',
                    style: const TextStyle(color: VantraTheme.redBlocked),
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
                            Icons.lock_outline_rounded,
                            size: 64,
                            color: VantraTheme.primary.withValues(alpha: 0.4),
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'No messages yet',
                            style: TextStyle(
                              color: VantraTheme.textPrimary,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'End-to-End Encrypted with ChaCha20-Poly1305',
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
                                  colors: [VantraTheme.primary, VantraTheme.secondary],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                )
                              : null,
                          color: isMe ? null : VantraTheme.surface,
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(16),
                            topRight: const Radius.circular(16),
                            bottomLeft: isMe ? const Radius.circular(16) : const Radius.circular(2),
                            bottomRight: isMe ? const Radius.circular(2) : const Radius.circular(16),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.15),
                              blurRadius: 3,
                              offset: const Offset(0, 1.5),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (msg.type == 'IMAGE') ...[
                              GestureDetector(
                                onTap: msg.mediaPath != null
                                    ? () => _showFullscreenImage(msg.mediaPath!)
                                    : null,
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: msg.mediaPath != null
                                          ? Image.file(
                                              File(msg.mediaPath!),
                                              width: 200,
                                              fit: BoxFit.cover,
                                              errorBuilder: (context, error, stackTrace) => Container(
                                                width: 200,
                                                height: 150,
                                                color: Colors.white10,
                                                child: const Icon(Icons.broken_image_rounded, color: VantraTheme.textMuted),
                                              ),
                                            )
                                          : Container(
                                              width: 200,
                                              height: 150,
                                              color: Colors.white10,
                                              child: const Center(
                                                child: CircularProgressIndicator(color: VantraTheme.primary),
                                              ),
                                            ),
                                    ),
                                    if (msg.status == MessageStatus.sending ||
                                        (msg.status == MessageStatus.pending &&
                                            ref.watch(messagingStateProvider.notifier).getTransferProgress(msg.transferId ?? '') > 0)) ...[
                                      Consumer(
                                        builder: (context, ref, child) {
                                          final progress = ref.watch(messagingStateProvider.notifier).getTransferProgress(msg.transferId ?? '');
                                          return Container(
                                            width: 200,
                                            height: 150,
                                            decoration: BoxDecoration(
                                              color: Colors.black54,
                                              borderRadius: BorderRadius.circular(12),
                                            ),
                                            child: Center(
                                              child: Column(
                                                mainAxisAlignment: MainAxisAlignment.center,
                                                children: [
                                                  CircularProgressIndicator(
                                                    value: progress,
                                                    color: VantraTheme.primary,
                                                  ),
                                                  const SizedBox(height: 8),
                                                  Text(
                                                    '${(progress * 100).toInt()}%',
                                                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              if (msg.text.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(
                                  msg.text,
                                  style: const TextStyle(
                                    color: VantraTheme.textPrimary,
                                    fontSize: 14.5,
                                    height: 1.3,
                                  ),
                                ),
                              ],
                            ] else if (msg.type == 'FILE') ...[
                              GestureDetector(
                                onTap: msg.mediaPath != null
                                    ? () {
                                        showModalBottomSheet(
                                          context: context,
                                          backgroundColor: VantraTheme.surface,
                                          shape: const RoundedRectangleBorder(
                                            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                                          ),
                                          builder: (context) {
                                            return SafeArea(
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  ListTile(
                                                    leading: const Icon(Icons.open_in_new_rounded, color: VantraTheme.primaryAccent),
                                                    title: const Text('Open File', style: TextStyle(color: VantraTheme.textPrimary)),
                                                    onTap: () {
                                                      Navigator.of(context).pop();
                                                      OpenFilex.open(msg.mediaPath!);
                                                    },
                                                  ),
                                                  ListTile(
                                                    leading: const Icon(Icons.share_rounded, color: VantraTheme.primaryAccent),
                                                    title: const Text('Share / Export', style: TextStyle(color: VantraTheme.textPrimary)),
                                                    onTap: () {
                                                      Navigator.of(context).pop();
                                                      Share.shareXFiles([XFile(msg.mediaPath!)], text: msg.fileName);
                                                    },
                                                  ),
                                                ],
                                              ),
                                            );
                                          },
                                        );
                                      }
                                    : null,
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.white10,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.insert_drive_file_rounded,
                                            color: isMe ? Colors.white : VantraTheme.primary,
                                            size: 36,
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  msg.fileName ?? 'Unknown file',
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.bold,
                                                    color: isMe ? Colors.white : VantraTheme.textPrimary,
                                                  ),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  (msg.fileSize ?? 0) / 1024 > 1024
                                                      ? '${((msg.fileSize ?? 0) / (1024 * 1024)).toStringAsFixed(1)} MB'
                                                      : '${((msg.fileSize ?? 0) / 1024).toStringAsFixed(1)} KB',
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    color: isMe ? Colors.white70 : VantraTheme.textSecondary,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (msg.status == MessageStatus.sending ||
                                          (msg.status == MessageStatus.pending &&
                                              ref.watch(messagingStateProvider.notifier).getTransferProgress(msg.transferId ?? '') > 0)) ...[
                                        const SizedBox(height: 8),
                                        Consumer(
                                          builder: (context, ref, child) {
                                            final progress = ref.watch(messagingStateProvider.notifier).getTransferProgress(msg.transferId ?? '');
                                            return Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                LinearProgressIndicator(
                                                  value: progress,
                                                  color: isMe ? Colors.white : VantraTheme.primary,
                                                  backgroundColor: Colors.white12,
                                                ),
                                                const SizedBox(height: 4),
                                                Row(
                                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                  children: [
                                                    Text(
                                                      '${(progress * 100).toInt()}%',
                                                      style: TextStyle(
                                                        color: isMe ? Colors.white70 : VantraTheme.textSecondary,
                                                        fontSize: 10,
                                                      ),
                                                    ),
                                                    Text(
                                                      msg.status == MessageStatus.sending ? 'Transferring...' : 'Pending...',
                                                      style: TextStyle(
                                                        color: isMe ? Colors.white70 : VantraTheme.textSecondary,
                                                        fontSize: 10,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            );
                                          },
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                              if (msg.text.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(
                                  msg.text,
                                  style: const TextStyle(
                                    color: VantraTheme.textPrimary,
                                    fontSize: 14.5,
                                    height: 1.3,
                                  ),
                                ),
                              ],
                            ] else ...[
                              Text(
                                msg.text,
                                style: const TextStyle(
                                  color: VantraTheme.textPrimary,
                                  fontSize: 14.5,
                                  height: 1.3,
                                ),
                              ),
                            ],
                            const SizedBox(height: 5),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _formatTimestamp(msg.timestamp),
                                  style: TextStyle(
                                    color: isMe ? Colors.white70 : VantraTheme.textSecondary,
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: const BoxDecoration(
                color: VantraTheme.surface,
                border: Border(top: BorderSide(color: Colors.white10, width: 0.5)),
              ),
              child: SafeArea(
                child: Row(
                  children: [
                    IconButton(
                      key: const Key('chat_attach_button'),
                      icon: const Icon(Icons.add_photo_alternate_rounded, color: VantraTheme.primaryAccent),
                      onPressed: ((isConnected || isTrusted) && !isBlocked) ? _pickAndPreviewImage : null,
                    ),
                    IconButton(
                      key: const Key('chat_attach_file_button'),
                      icon: const Icon(Icons.attach_file_rounded, color: VantraTheme.primaryAccent),
                      onPressed: ((isConnected || isTrusted) && !isBlocked) ? _pickAndPreviewFile : null,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: VantraTheme.background,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: Colors.white10, width: 0.5),
                        ),
                        child: TextField(
                          key: const Key('chat_input_field'),
                          controller: _controller,
                          enabled: (isConnected || isTrusted) && !isBlocked,
                          textCapitalization: TextCapitalization.sentences,
                          style: const TextStyle(color: VantraTheme.textPrimary),
                          decoration: InputDecoration(
                            hintText: isBlocked
                                ? 'Peer is blocked'
                                : (isConnected || isTrusted)
                                    ? 'Type an encrypted message...'
                                    : 'Disconnected',
                            hintStyle: const TextStyle(color: VantraTheme.textMuted),
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      decoration: const BoxDecoration(
                        color: VantraTheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        key: const Key('chat_send_button'),
                        icon: const Icon(
                          Icons.send_rounded,
                          color: Colors.white,
                        ),
                        onPressed: ((isConnected || isTrusted) && !isBlocked)
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
