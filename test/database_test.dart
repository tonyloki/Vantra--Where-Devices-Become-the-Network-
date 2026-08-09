import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/models/message_status.dart';
import 'package:vantra/core/models/peer_trust_state.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('Database Initialization & PeerDao Tests', () {
    test('Database initializes successfully', () {
      expect(db, isNotNull);
    });

    test('Peer can be inserted, retrieved, and updated', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      
      // 1. Insert a peer
      await db.peerDao.insertOrUpdatePeer(Peer(
        peerId: 'peer-abc',
        displayName: 'Device A',
        lastKnownEndpointId: 'QHZD',
        trustState: PeerTrustState.untrusted,
        lastSeen: now,
        createdAt: now,
        updatedAt: now,
      ));

      final peer = await db.peerDao.getPeer('peer-abc');
      expect(peer, isNotNull);
      expect(peer!.displayName, 'Device A');
      expect(peer.lastKnownEndpointId, 'QHZD');

      // 2. Update display name & endpointId (same peerId)
      await db.peerDao.insertOrUpdatePeer(Peer(
        peerId: 'peer-abc',
        displayName: 'Device A New Name',
        lastKnownEndpointId: 'XVAA',
        trustState: PeerTrustState.untrusted,
        lastSeen: now + 1000,
        createdAt: now,
        updatedAt: now + 1000,
      ));

      final updatedPeer = await db.peerDao.getPeer('peer-abc');
      expect(updatedPeer, isNotNull);
      expect(updatedPeer!.displayName, 'Device A New Name');
      expect(updatedPeer.lastKnownEndpointId, 'XVAA'); // updated endpointId

      // Verify no duplicates created
      final allPeers = await db.peerDao.listPeers();
      expect(allPeers.length, 1);
    });
  });

  group('MessageDao Tests', () {
    test('Insert and retrieve messages', () async {
      final now = DateTime.now().millisecondsSinceEpoch;

      final msg = MessagesCompanion.insert(
        messageId: 'msg-1',
        senderId: 'me',
        receiverId: 'peer-abc',
        messageText: 'Hello Peer',
        timestamp: now,
        type: 'TEXT',
        status: MessageStatus.sent,
        createdAt: now,
      );

      await db.messageDao.insertMessage(msg);

      final retrieved = await db.messageDao.getMessageById('msg-1');
      expect(retrieved, isNotNull);
      expect(retrieved!.messageText, 'Hello Peer');
      expect(retrieved.status, MessageStatus.sent);
    });

    test('Update message status', () async {
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.messageDao.insertMessage(MessagesCompanion.insert(
        messageId: 'msg-update',
        senderId: 'me',
        receiverId: 'peer-abc',
        messageText: 'Pending Text',
        timestamp: now,
        type: 'TEXT',
        status: MessageStatus.pending,
        createdAt: now,
      ));

      final before = await db.messageDao.getMessageById('msg-update');
      expect(before!.status, MessageStatus.pending);

      final success = await db.messageDao.updateMessageStatus('msg-update', MessageStatus.sent);
      expect(success, isTrue);

      final after = await db.messageDao.getMessageById('msg-update');
      expect(after!.status, MessageStatus.sent);
    });

    test('Bilateral conversation query & ordering & separation', () async {
      final now = DateTime.now().millisecondsSinceEpoch;

      // Local sends to peer-abc
      await db.messageDao.insertMessage(MessagesCompanion.insert(
        messageId: 'm-1',
        senderId: 'me',
        receiverId: 'peer-abc',
        messageText: 'Message 1',
        timestamp: now,
        type: 'TEXT',
        status: MessageStatus.sent,
        createdAt: now,
      ));

      // Peer-abc replies to local
      await db.messageDao.insertMessage(MessagesCompanion.insert(
        messageId: 'm-2',
        senderId: 'peer-abc',
        receiverId: 'me',
        messageText: 'Message 2',
        timestamp: now + 10,
        type: 'TEXT',
        status: MessageStatus.received,
        createdAt: now + 10,
      ));

      // Separate conversation: local to peer-xyz (should not mix!)
      await db.messageDao.insertMessage(MessagesCompanion.insert(
        messageId: 'm-3',
        senderId: 'me',
        receiverId: 'peer-xyz',
        messageText: 'Message to XYZ',
        timestamp: now + 20,
        type: 'TEXT',
        status: MessageStatus.sent,
        createdAt: now + 20,
      ));

      // Query conversation between 'me' and 'peer-abc'
      final conversation = await db.messageDao.getConversation('me', 'peer-abc');
      
      expect(conversation.length, 2);
      expect(conversation[0].messageId, 'm-1'); // ordered by localId
      expect(conversation[0].messageText, 'Message 1');
      expect(conversation[1].messageId, 'm-2');
      expect(conversation[1].messageText, 'Message 2');
    });

    test('Duplicate messageId unique constraint protects database', () async {
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.messageDao.insertMessage(MessagesCompanion.insert(
        messageId: 'msg-unique',
        senderId: 'me',
        receiverId: 'peer-abc',
        messageText: 'First try',
        timestamp: now,
        type: 'TEXT',
        status: MessageStatus.sent,
        createdAt: now,
      ));

      // Trying to insert duplicate messageId should throw sqlite/Drift exception
      expect(
        () => db.messageDao.insertMessage(MessagesCompanion.insert(
          messageId: 'msg-unique',
          senderId: 'me',
          receiverId: 'peer-abc',
          messageText: 'Second try',
          timestamp: now,
          type: 'TEXT',
          status: MessageStatus.sent,
          createdAt: now,
        )),
        throwsException,
      );
    });
  });
}
