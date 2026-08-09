import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/messaging/message.dart';
import 'package:vantra/core/messaging/messaging_repository.dart';
import 'package:vantra/core/models/message_status.dart';
import 'package:vantra/core/models/peer_trust_state.dart';

void main() {
  late AppDatabase db;
  late MessagingRepository repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = MessagingRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('Conversations & Unread Count Tests', () {
    test('Incoming unread messages increment unread count and clear on markAsRead', () async {
      const localPeerId = 'local-device';
      const remotePeerId = 'remote-peer';

      // Seed peer
      await repo.upsertPeer(remotePeerId, 'RemoteUser', trustState: PeerTrustState.trusted);

      // Save 3 incoming messages while unread
      final now = DateTime.now().millisecondsSinceEpoch;
      await repo.saveIncomingMessage(
        VantraMessage(
          messageId: 'm1',
          senderId: remotePeerId,
          receiverId: localPeerId,
          text: 'Message 1',
          timestamp: now - 3000,
          status: MessageStatus.received,
        ),
        isRead: false,
      );

      await repo.saveIncomingMessage(
        VantraMessage(
          messageId: 'm2',
          senderId: remotePeerId,
          receiverId: localPeerId,
          text: 'Message 2',
          timestamp: now - 2000,
          status: MessageStatus.received,
        ),
        isRead: false,
      );

      await repo.saveIncomingMessage(
        VantraMessage(
          messageId: 'm3',
          senderId: remotePeerId,
          receiverId: localPeerId,
          text: 'Message 3',
          timestamp: now - 1000,
          status: MessageStatus.received,
        ),
        isRead: false,
      );

      var summaries = await repo.watchConversationSummaries(localPeerId, {}).first;
      expect(summaries.length, 1);
      expect(summaries[0].unreadCount, 3);
      expect(summaries[0].lastMessageText, 'Message 3');

      // User opens conversation
      await repo.markConversationAsRead(localPeerId, remotePeerId);

      summaries = await repo.watchConversationSummaries(localPeerId, {}).first;
      expect(summaries.length, 1);
      expect(summaries[0].unreadCount, 0);
    });

    test('Conversation summaries are sorted by newest message first', () async {
      const localPeerId = 'local-device';
      const peer1 = 'peer-1';
      const peer2 = 'peer-2';

      await repo.upsertPeer(peer1, 'Alice');
      await repo.upsertPeer(peer2, 'Bob');

      final now = DateTime.now().millisecondsSinceEpoch;

      // Alice sends message at now - 5000
      await repo.saveIncomingMessage(
        VantraMessage(
          messageId: 'msg-alice',
          senderId: peer1,
          receiverId: localPeerId,
          text: 'Hi from Alice',
          timestamp: now - 5000,
          status: MessageStatus.received,
        ),
        isRead: true,
      );

      // Bob sends message at now - 1000 (newer)
      await repo.saveIncomingMessage(
        VantraMessage(
          messageId: 'msg-bob',
          senderId: peer2,
          receiverId: localPeerId,
          text: 'Hi from Bob',
          timestamp: now - 1000,
          status: MessageStatus.received,
        ),
        isRead: true,
      );

      final summaries = await repo.watchConversationSummaries(localPeerId, {}).first;
      expect(summaries.length, 2);
      expect(summaries[0].peerId, peer2); // Bob first (newer)
      expect(summaries[1].peerId, peer1); // Alice second
    });
  });
}
