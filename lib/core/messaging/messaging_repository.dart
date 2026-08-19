import 'dart:async';
import 'package:drift/drift.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/models/conversation_summary.dart';
import 'package:vantra/core/models/message_status.dart';
import 'package:vantra/core/models/peer_session.dart';
import 'package:vantra/core/models/peer_trust_state.dart';
import 'package:vantra/core/utils/logger.dart';
import 'message.dart';

class MessagingRepository {
  final AppDatabase _db;

  MessagingRepository(this._db);

  /// Saves an outgoing message locally in the pending status
  Future<void> saveOutgoingMessage(VantraMessage msg) async {
    final companion = MessagesCompanion.insert(
      messageId: msg.messageId,
      senderId: msg.senderId,
      receiverId: msg.receiverId,
      messageText: msg.text,
      timestamp: msg.timestamp,
      type: msg.type,
      status: MessageStatus.pending,
      isRead: const Value(true), // Outgoing messages are inherently read locally
      createdAt: DateTime.now().millisecondsSinceEpoch,
      mediaPath: Value(msg.mediaPath),
      mimeType: Value(msg.mimeType),
      fileName: Value(msg.fileName),
      fileSize: Value(msg.fileSize),
      width: Value(msg.width),
      height: Value(msg.height),
      transferId: Value(msg.transferId),
      sha256: Value(msg.sha256),
    );
    await _db.messageDao.insertMessage(companion);
  }

  /// Saves an incoming message locally with isRead: false.
  Future<void> saveIncomingMessage(VantraMessage msg, {bool isRead = false}) async {
    VantraLogger.log('[VANTRA][PERSISTENCE] PERSISTENCE INSERT START: messageId=${msg.messageId}, senderId=${msg.senderId}, receiverId=${msg.receiverId}, status=received');
    try {
      // Repository-level duplicate protection
      final existing = await _db.messageDao.getMessageById(msg.messageId);
      if (existing != null) {
        VantraLogger.log('[VANTRA][PERSISTENCE] DUPLICATE IGNORED: messageId=${msg.messageId}');
        return;
      }

      final companion = MessagesCompanion.insert(
        messageId: msg.messageId,
        senderId: msg.senderId,
        receiverId: msg.receiverId,
        messageText: msg.text,
        timestamp: msg.timestamp,
        type: msg.type,
        status: msg.status,
        isRead: Value(isRead),
        createdAt: DateTime.now().millisecondsSinceEpoch,
        mediaPath: Value(msg.mediaPath),
        mimeType: Value(msg.mimeType),
        fileName: Value(msg.fileName),
        fileSize: Value(msg.fileSize),
        width: Value(msg.width),
        height: Value(msg.height),
        transferId: Value(msg.transferId),
        sha256: Value(msg.sha256),
      );
      await _db.messageDao.insertMessage(companion);
      VantraLogger.log('[VANTRA][PERSISTENCE] PERSISTENCE INSERT SUCCESS: messageId=${msg.messageId}');
    } catch (e, stack) {
      VantraLogger.log('[VANTRA][PERSISTENCE] PERSISTENCE INSERT FAILED: messageId=${msg.messageId}, error=$e', e, stack);
      rethrow;
    }
  }

  /// Updates message transmission status
  Future<bool> updateMessageStatus(String messageId, MessageStatus status) async {
    print('[VANTRA][MESSAGE] DELIVERY_STATE messageId=$messageId state=${status.name}');
    final dbMsg = await _db.messageDao.getMessageById(messageId);
    if (dbMsg != null && (dbMsg.type == 'IMAGE' || dbMsg.type == 'FILE')) {
      print('[VANTRA][MEDIA][STATUS_UPDATE]\n'
            'messageId=$messageId\n'
            'oldStatus=${dbMsg.status.name}\n'
            'newStatus=${status.name}');
    }
    return _db.messageDao.updateMessageStatus(messageId, status);
  }

  /// Marks all incoming unread messages in a conversation as read
  Future<int> markConversationAsRead(String localPeerId, String remotePeerId) {
    return _db.messageDao.markConversationAsRead(localPeerId, remotePeerId);
  }

  /// Subscribes to a conversation stream (ordered by local sequence id)
  Stream<List<VantraMessage>> watchConversation(String localPeerId, String remotePeerId) {
    return _db.messageDao.watchConversation(localPeerId, remotePeerId).map((list) {
      VantraLogger.log('[VANTRA][PERSISTENCE] CONVERSATION STREAM EMIT: localPeerId=$localPeerId, remotePeerId=$remotePeerId, count=${list.length}');
      return list.map((dbMsg) => _mapToDomain(dbMsg)).toList();
    });
  }

  /// Loads historical messages chronologically (ordered by local sequence id)
  Future<List<VantraMessage>> getConversation(String localPeerId, String remotePeerId) async {
    final list = await _db.messageDao.getConversation(localPeerId, remotePeerId);
    return list.map((dbMsg) => _mapToDomain(dbMsg)).toList();
  }

  /// Subscribes to all conversation summaries reactively
  Stream<List<ConversationSummary>> watchConversationSummaries(
    String localPeerId,
    Map<String, PeerSession> activeSessions,
  ) {
    final peersStream = _db.peerDao.watchAllPeers();

    final latestMessagesStream = _db.customSelect(
      'SELECT * FROM messages WHERE local_id IN ( '
      '  SELECT MAX(local_id) FROM messages GROUP BY '
      '  CASE WHEN sender_id = ? THEN receiver_id ELSE sender_id END'
      ')',
      variables: [Variable.withString(localPeerId)],
      readsFrom: {_db.messages},
    ).watch().map((rows) {
      return rows.map((row) => _db.messages.map(row.data)).toList();
    });

    final unreadCountsStream = _db.customSelect(
      'SELECT sender_id, COUNT(*) as unread_count FROM messages '
      'WHERE receiver_id = ? AND is_read = 0 GROUP BY sender_id',
      variables: [Variable.withString(localPeerId)],
      readsFrom: {_db.messages},
    ).watch().map((rows) {
      return {
        for (final row in rows)
          row.read<String>('sender_id'): row.read<int>('unread_count')
      };
    });

    return _combineLatest3<List<Peer>, List<Message>, Map<String, int>, List<ConversationSummary>>(
      peersStream,
      latestMessagesStream,
      unreadCountsStream,
      (peerList, latestMessages, unreadCounts) {
        final summaries = <ConversationSummary>[];

        final latestMap = <String, Message>{};
        for (final msg in latestMessages) {
          final remoteId = msg.senderId == localPeerId ? msg.receiverId : msg.senderId;
          latestMap[remoteId] = msg;
        }

        for (final peer in peerList) {
          final lastMsg = latestMap[peer.peerId];
          final activeSession = activeSessions[peer.peerId];
          final isTrusted = peer.trustState == PeerTrustState.trusted;
          final isOnline = activeSession?.status == SessionStatus.connected;

          if (lastMsg == null && !isTrusted && !isOnline) {
            continue;
          }

          if (lastMsg == null) {
            summaries.add(ConversationSummary(
              peerId: peer.peerId,
              displayName: peer.displayName,
              nickname: peer.nickname,
              fingerprint: peer.fingerprint,
              trustState: peer.trustState,
              lastMessageText: 'Start chatting',
              lastMessageTimestamp: peer.updatedAt,
              lastMessageStatus: MessageStatus.received,
              isOutgoing: false,
              unreadCount: 0,
              isOnline: isOnline,
              isSecure: activeSession?.isSecure == true,
            ));
          } else {
            final unreadCount = unreadCounts[peer.peerId] ?? 0;

            String previewText = lastMsg.messageText;
            if (lastMsg.type == 'IMAGE') {
              previewText = lastMsg.messageText.isNotEmpty ? lastMsg.messageText : '📷 Photo';
            } else if (lastMsg.type == 'FILE') {
              previewText = lastMsg.messageText.isNotEmpty ? lastMsg.messageText : '📁 File: ${lastMsg.fileName ?? "Attachment"}';
            }

            summaries.add(ConversationSummary(
              peerId: peer.peerId,
              displayName: peer.displayName,
              nickname: peer.nickname,
              fingerprint: peer.fingerprint,
              trustState: peer.trustState,
              lastMessageText: previewText,
              lastMessageTimestamp: lastMsg.timestamp,
              lastMessageStatus: lastMsg.status,
              isOutgoing: lastMsg.senderId == localPeerId,
              unreadCount: unreadCount,
              isOnline: isOnline,
              isSecure: activeSession?.isSecure == true,
            ));
          }
        }

        summaries.sort((a, b) => b.lastMessageTimestamp.compareTo(a.lastMessageTimestamp));
        return summaries;
      },
    );
  }

  Stream<T> _combineLatest3<A, B, C, T>(
    Stream<A> streamA,
    Stream<B> streamB,
    Stream<C> streamC,
    T Function(A a, B b, C c) combiner,
  ) {
    final controller = StreamController<T>.broadcast();
    StreamSubscription<A>? subA;
    StreamSubscription<B>? subB;
    StreamSubscription<C>? subC;

    A? latestA;
    B? latestB;
    C? latestC;

    bool hasA = false;
    bool hasB = false;
    bool hasC = false;

    void emitIfReady() {
      if (hasA && hasB && hasC) {
        if (!controller.isClosed) {
          controller.add(combiner(latestA as A, latestB as B, latestC as C));
        }
      }
    }

    controller.onListen = () {
      subA = streamA.listen((val) {
        latestA = val;
        hasA = true;
        emitIfReady();
      }, onError: (Object err, StackTrace st) {
        if (!controller.isClosed) controller.addError(err, st);
      });

      subB = streamB.listen((val) {
        latestB = val;
        hasB = true;
        emitIfReady();
      }, onError: (Object err, StackTrace st) {
        if (!controller.isClosed) controller.addError(err, st);
      });

      subC = streamC.listen((val) {
        latestC = val;
        hasC = true;
        emitIfReady();
      }, onError: (Object err, StackTrace st) {
        if (!controller.isClosed) controller.addError(err, st);
      });
    };

    controller.onCancel = () {
      subA?.cancel();
      subB?.cancel();
      subC?.cancel();
    };

    return controller.stream;
  }

  /// Creates/Updates known peer records in SQLite
  Future<void> upsertPeer(
    String peerId,
    String displayName, {
    String? nickname,
    String? endpointId,
    String? publicKey,
    String? fingerprint,
    PeerTrustState? trustState,
    int? protocolVersion,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await _db.peerDao.getPeer(peerId);

    if (existing == null) {
      await _db.peerDao.insertOrUpdatePeer(Peer(
        peerId: peerId,
        displayName: displayName,
        nickname: nickname,
        lastKnownEndpointId: endpointId,
        publicKey: publicKey,
        fingerprint: fingerprint,
        trustState: trustState ?? PeerTrustState.untrusted,
        protocolVersion: protocolVersion ?? 1,
        lastSeen: now,
        createdAt: now,
        updatedAt: now,
      ));
    } else {
      await _db.peerDao.insertOrUpdatePeer(existing.copyWith(
        displayName: displayName,
        nickname: Value(nickname ?? existing.nickname),
        lastKnownEndpointId: Value(endpointId ?? existing.lastKnownEndpointId),
        publicKey: Value(publicKey ?? existing.publicKey),
        fingerprint: Value(fingerprint ?? existing.fingerprint),
        trustState: trustState ?? existing.trustState,
        protocolVersion: Value(protocolVersion ?? existing.protocolVersion),
        lastSeen: now,
        updatedAt: now,
      ));
    }
  }

  /// Updates local nickname for a peer without transmitting or changing displayName
  Future<void> updatePeerNickname(String peerId, String? nickname) async {
    await _db.peerDao.updateNickname(peerId, nickname);
  }

  /// Updates peer trust state directly (e.g. after out-of-band verification or block)
  Future<void> updatePeerTrustState(String peerId, PeerTrustState trustState) async {
    await _db.peerDao.updateTrustState(peerId, trustState);
  }

  /// Verifies a peer's identity and stores the verified public key
  Future<void> updatePeerVerification(String peerId, String verifiedPublicKey) async {
    await _db.peerDao.updatePeerVerification(peerId, verifiedPublicKey);
  }

  /// Updates peer lastSeen timestamp
  Future<void> updatePeerLastSeen(String peerId, int lastSeen) async {
    await _db.peerDao.updateLastSeen(peerId, lastSeen);
  }

  Future<Peer?> getPeer(String peerId) {
    return _db.peerDao.getPeer(peerId);
  }

  Stream<Peer?> watchPeer(String peerId) {
    return _db.peerDao.watchPeer(peerId);
  }

  Stream<List<Peer>> watchPeers() {
    return _db.peerDao.watchPeers();
  }

  Stream<List<Peer>> watchTrustedPeers() {
    return _db.peerDao.watchTrustedPeers();
  }

  Stream<List<Peer>> watchBlockedPeers() {
    return _db.peerDao.watchBlockedPeers();
  }

  Future<List<Peer>> searchPeers(String query) {
    return _db.peerDao.searchPeers(query);
  }

  Future<VantraMessage?> getMessageById(String messageId) async {
    final dbMsg = await _db.messageDao.getMessageById(messageId);
    if (dbMsg == null) return null;
    return _mapToDomain(dbMsg);
  }

  Future<List<VantraMessage>> getPendingOrFailedMessages(String peerId) async {
    final list = await _db.messageDao.getPendingOrFailedMessages(peerId);
    return list.map((dbMsg) => _mapToDomain(dbMsg)).toList();
  }

  Future<List<VantraMessage>> getAllPendingOrFailedMessages() async {
    final list = await _db.messageDao.getAllPendingOrFailedMessages();
    return list.map((dbMsg) => _mapToDomain(dbMsg)).toList();
  }

  Future<void> recoverSentMessages() {
    return _db.messageDao.recoverSentMessages();
  }

  Future<void> incrementRetryCount(String messageId, {int maxAttempts = 5}) {
    return _db.messageDao.incrementRetryCount(messageId, maxAttempts: maxAttempts);
  }

  Future<VantraMessage?> getMessageByTransferId(String transferId) async {
    final msg = await _db.messageDao.getMessageByTransferId(transferId);
    return msg != null ? _mapToDomain(msg) : null;
  }

  Future<bool> updateIncomingMediaDetails(String messageId, String mediaPath, MessageStatus status) async {
    final dbMsg = await _db.messageDao.getMessageById(messageId);
    if (dbMsg != null) {
      print('[VANTRA][MEDIA][STATUS_UPDATE]\n'
            'messageId=$messageId\n'
            'oldStatus=${dbMsg.status.name}\n'
            'newStatus=${status.name}');
    }
    return _db.messageDao.updateIncomingMediaDetails(messageId, mediaPath, status);
  }

  VantraMessage _mapToDomain(Message dbMsg) {
    return VantraMessage(
      messageId: dbMsg.messageId,
      senderId: dbMsg.senderId,
      receiverId: dbMsg.receiverId,
      text: dbMsg.messageText,
      timestamp: dbMsg.timestamp,
      status: dbMsg.status,
      retryCount: dbMsg.retryCount,
      type: dbMsg.type,
      mediaPath: dbMsg.mediaPath,
      mimeType: dbMsg.mimeType,
      fileName: dbMsg.fileName,
      fileSize: dbMsg.fileSize,
      width: dbMsg.width,
      height: dbMsg.height,
      transferId: dbMsg.transferId,
      sha256: dbMsg.sha256,
    );
  }

  Future<int> clearConversation(String localPeerId, String remotePeerId) {
    return _db.messageDao.clearConversation(localPeerId, remotePeerId);
  }

  Future<int> deleteMessage(String messageId) {
    return _db.messageDao.deleteMessageById(messageId);
  }

  Future<void> deletePeerAndHistory(String peerId, String localPeerId) async {
    await _db.peerDao.deletePeerById(peerId);
    await _db.messageDao.clearConversation(localPeerId, peerId);
  }
}

