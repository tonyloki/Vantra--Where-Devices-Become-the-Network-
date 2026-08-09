import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:drift/native.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/models/message_status.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeTransport fakeTransport;
  late ProviderContainer container;
  late AppDatabase testDb;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    fakeTransport = FakeTransport();
    testDb = AppDatabase.forTesting(NativeDatabase.memory());

    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        transportProvider.overrideWithValue(fakeTransport),
        appDatabaseProvider.overrideWithValue(testDb),
      ],
    );
  });

  tearDown(() async {
    await testDb.close();
    container.dispose();
  });

  group('Messaging Pipeline Persistence Tests', () {
    test('Identity handshake updates Peer table but does not create chat messages', () async {
      // 1. Initialize MessagingState notifier
      container.read(messagingStateProvider);

      final remotePeerId = const Uuid().v4();
      final remotePayload = {
        'type': 'IDENTITY',
        'peerId': remotePeerId,
        'displayName': 'VantraRemotePeer',
      };

      // 2. Trigger handshake payload
      fakeTransport.triggerIncomingPayload('QHZD', Uint8List.fromList(utf8.encode(jsonEncode(remotePayload))));
      await Future.delayed(const Duration(milliseconds: 50));

      // 3. Verify Peer record exists in database
      final repo = container.read(messagingRepositoryProvider);
      final dbPeer = await repo.getPeer(remotePeerId);
      expect(dbPeer, isNotNull);
      expect(dbPeer!.displayName, 'VantraRemotePeer');
      expect(dbPeer.lastKnownEndpointId, 'QHZD');

      // 4. Verify no chat messages were created in database
      final localIdentity = container.read(localIdentityStateProvider);
      final messages = await repo.getConversation(localIdentity.peerId, remotePeerId);
      expect(messages.isEmpty, isTrue);
    });

    test('Incoming message is persisted with received status and protects against duplicates', () async {
      container.read(messagingStateProvider);

      final remotePeerId = const Uuid().v4();
      final localIdentity = container.read(localIdentityStateProvider);
      final repo = container.read(messagingRepositoryProvider);
      final messageId = const Uuid().v4();

      final textPayload = {
        'type': 'TEXT',
        'messageId': messageId,
        'senderId': remotePeerId,
        'receiverId': localIdentity.peerId,
        'text': 'Hello Persistence World',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      // 1. Deliver message payload
      fakeTransport.triggerIncomingPayload('QHZD', Uint8List.fromList(utf8.encode(jsonEncode(textPayload))));
      await Future.delayed(const Duration(milliseconds: 50));

      // 2. Verify persisted in database
      var messages = await repo.getConversation(localIdentity.peerId, remotePeerId);
      expect(messages.length, 1);
      expect(messages[0].text, 'Hello Persistence World');
      expect(messages[0].status, MessageStatus.received);

      // 3. Deliver same duplicate payload again
      fakeTransport.triggerIncomingPayload('QHZD', Uint8List.fromList(utf8.encode(jsonEncode(textPayload))));
      await Future.delayed(const Duration(milliseconds: 50));

      // 4. Verify database still contains exactly 1 row (duplicate protection)
      messages = await repo.getConversation(localIdentity.peerId, remotePeerId);
      expect(messages.length, 1);
    });

    test('Outgoing message is persisted with pending status and becomes sent on success', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      container.read(messagingStateProvider);

      // Connect endpoint first so session is marked connected
      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'QHZD',
        status: ConnectionStatus.connected,
        endpointName: 'QHZD',
      ));
      await Future.delayed(Duration.zero);

      final remotePeerId = const Uuid().v4();
      final remotePayload = {
        'type': 'IDENTITY',
        'peerId': remotePeerId,
        'displayName': 'VantraRemote',
      };
      fakeTransport.triggerIncomingPayload('QHZD', Uint8List.fromList(utf8.encode(jsonEncode(remotePayload))));
      await Future.delayed(const Duration(milliseconds: 50));

      // Send message
      await notifier.sendTextMessage(remotePeerId, 'Outbound text');

      // Verify status becomes sent
      final localIdentity = container.read(localIdentityStateProvider);
      final repo = container.read(messagingRepositoryProvider);
      final messages = await repo.getConversation(localIdentity.peerId, remotePeerId);
      expect(messages.length, 1);
      expect(messages[0].text, 'Outbound text');
      expect(messages[0].status, MessageStatus.sent);
    });

    test('Outgoing message is persisted and becomes failed if transport throws error', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      container.read(messagingStateProvider);

      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'QHZD',
        status: ConnectionStatus.connected,
        endpointName: 'QHZD',
      ));
      await Future.delayed(Duration.zero);

      final remotePeerId = const Uuid().v4();
      final remotePayload = {
        'type': 'IDENTITY',
        'peerId': remotePeerId,
        'displayName': 'VantraRemote',
      };
      fakeTransport.triggerIncomingPayload('QHZD', Uint8List.fromList(utf8.encode(jsonEncode(remotePayload))));
      await Future.delayed(const Duration(milliseconds: 50));

      // Make transport throw error on next send
      fakeTransport.throwErrorOnSend = true;

      // Try sending and catch the error
      try {
        await notifier.sendTextMessage(remotePeerId, 'Outbound error text');
      } catch (_) {}

      // Verify status in database is failed
      final localIdentity = container.read(localIdentityStateProvider);
      final repo = container.read(messagingRepositoryProvider);
      final messages = await repo.getConversation(localIdentity.peerId, remotePeerId);
      expect(messages.length, 1);
      expect(messages[0].text, 'Outbound error text');
      expect(messages[0].status, MessageStatus.failed);
    });
  });
}
