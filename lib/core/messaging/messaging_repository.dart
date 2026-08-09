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
      type: 'TEXT',
      status: MessageStatus.pending,
      isRead: const Value(true), // Outgoing messages are inherently read locally
      createdAt: DateTime.now().millisecondsSinceEpoch,
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
        type: 'TEXT',
        status: MessageStatus.received,
        isRead: Value(isRead),
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      await _db.messageDao.insertMessage(companion);
      VantraLogger.log('[VANTRA][PERSISTENCE] PERSISTENCE INSERT SUCCESS: messageId=${msg.messageId}');
    } catch (e, stack) {
      VantraLogger.log('[VANTRA][PERSISTENCE] PERSISTENCE INSERT FAILED: messageId=${msg.messageId}, error=$e', e, stack);
      rethrow;
    }
  }

  /// Updates message transmission status
  Future<bool> updateMessageStatus(String messageId, MessageStatus status) {
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
    // Combine peers stream with messages stream to create reactive summaries
    return _db.peerDao.watchAllPeers().asyncMap((peerList) async {
      final summaries = <ConversationSummary>[];

      for (final peer in peerList) {
        // Skip blocked peers from normal conversation list if desired or display them with blocked indicator
        final conv = await _db.messageDao.getConversation(localPeerId, peer.peerId);
        if (conv.isEmpty) continue;

        final lastMsg = conv.last;
        final unreadCount = await _db.messageDao.getUnreadCount(localPeerId, peer.peerId);
        final activeSession = activeSessions[peer.peerId];

        summaries.add(ConversationSummary(
          peerId: peer.peerId,
          displayName: peer.displayName,
          nickname: peer.nickname,
          fingerprint: peer.fingerprint,
          trustState: peer.trustState,
          lastMessageText: lastMsg.messageText,
          lastMessageTimestamp: lastMsg.timestamp,
          lastMessageStatus: lastMsg.status,
          isOutgoing: lastMsg.senderId == localPeerId,
          unreadCount: unreadCount,
          isOnline: activeSession?.status == SessionStatus.connected,
          isSecure: activeSession?.isSecure == true,
        ));
      }

      // Sort summaries by latest message timestamp descending
      summaries.sort((a, b) => b.lastMessageTimestamp.compareTo(a.lastMessageTimestamp));
      return summaries;
    });
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

  VantraMessage _mapToDomain(Message dbMsg) {
    return VantraMessage(
      messageId: dbMsg.messageId,
      senderId: dbMsg.senderId,
      receiverId: dbMsg.receiverId,
      text: dbMsg.messageText,
      timestamp: dbMsg.timestamp,
      status: dbMsg.status,
      retryCount: dbMsg.retryCount,
    );
  }
}
