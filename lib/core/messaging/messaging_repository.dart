import 'dart:async';
import 'package:drift/drift.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/models/message_status.dart';
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
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _db.messageDao.insertMessage(companion);
  }

  /// Saves an incoming message locally. If messageId already exists, it is safely ignored.
  Future<void> saveIncomingMessage(VantraMessage msg) async {
    // Repository-level duplicate protection
    final existing = await _db.messageDao.getMessageById(msg.messageId);
    if (existing != null) {
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
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _db.messageDao.insertMessage(companion);
  }

  /// Updates message transmission status
  Future<bool> updateMessageStatus(String messageId, MessageStatus status) {
    return _db.messageDao.updateMessageStatus(messageId, status);
  }

  /// Subscribes to a conversation stream (ordered by local sequence id)
  Stream<List<VantraMessage>> watchConversation(String localPeerId, String remotePeerId) {
    return _db.messageDao.watchConversation(localPeerId, remotePeerId).map((list) {
      return list.map((dbMsg) => _mapToDomain(dbMsg)).toList();
    });
  }

  /// Loads historical messages chronologically (ordered by local sequence id)
  Future<List<VantraMessage>> getConversation(String localPeerId, String remotePeerId) async {
    final list = await _db.messageDao.getConversation(localPeerId, remotePeerId);
    return list.map((dbMsg) => _mapToDomain(dbMsg)).toList();
  }

  /// Creates/Updates known peer records in SQLite
  Future<void> upsertPeer(String peerId, String displayName, {String? endpointId}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await _db.peerDao.getPeer(peerId);

    if (existing == null) {
      await _db.peerDao.insertOrUpdatePeer(Peer(
        peerId: peerId,
        displayName: displayName,
        lastKnownEndpointId: endpointId,
        lastSeen: now,
        createdAt: now,
        updatedAt: now,
      ));
    } else {
      await _db.peerDao.insertOrUpdatePeer(existing.copyWith(
        displayName: displayName,
        lastKnownEndpointId: Value(endpointId ?? existing.lastKnownEndpointId),
        lastSeen: now,
        updatedAt: now,
      ));
    }
  }

  Future<Peer?> getPeer(String peerId) {
    return _db.peerDao.getPeer(peerId);
  }

  Stream<List<Peer>> watchPeers() {
    return _db.peerDao.watchPeers();
  }

  VantraMessage _mapToDomain(Message dbMsg) {
    return VantraMessage(
      messageId: dbMsg.messageId,
      senderId: dbMsg.senderId,
      receiverId: dbMsg.receiverId,
      text: dbMsg.messageText,
      timestamp: dbMsg.timestamp,
      status: dbMsg.status,
    );
  }
}
