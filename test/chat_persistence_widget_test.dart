import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:drift/native.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/models/message_status.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/protocol/protocol_message.dart';
import 'package:vantra/core/protocol/protocol_version.dart';
import 'package:vantra/core/protocol/protobuf_codec.dart';
import 'package:vantra/core/security/crypto_service.dart';
import 'package:vantra/features/messaging/chat_page.dart';
import 'test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = ProtobufCodec();

  testWidgets('ChatPage renders historical SQLite messages and reactively displays new messages', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final fakeTransport = FakeTransport();
    final remotePeerId = const Uuid().v4();
    final localPeerId = const Uuid().v4();
    await prefs.setString('vantra_peer_id', localPeerId);

    final testDb = AppDatabase.forTesting(NativeDatabase.memory());
    final cryptoService = CryptoService();

    // 1. Seed database with historical messages
    final now = DateTime.now().millisecondsSinceEpoch;
    await testDb.messageDao.insertMessage(MessagesCompanion.insert(
      messageId: 'history-1',
      senderId: remotePeerId,
      receiverId: localPeerId,
      messageText: 'Hello from past history',
      timestamp: now - 5000,
      type: 'TEXT',
      status: MessageStatus.received,
      createdAt: now - 5000,
    ));

    await testDb.messageDao.insertMessage(MessagesCompanion.insert(
      messageId: 'history-2',
      senderId: localPeerId,
      receiverId: remotePeerId,
      messageText: 'My past response',
      timestamp: now - 1000,
      type: 'TEXT',
      status: MessageStatus.sent,
      createdAt: now - 1000,
    ));

    final fakeSecureStorage = FakeSecureStorageService();

    // 2. Render ChatPage
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          transportProvider.overrideWithValue(fakeTransport),
          appDatabaseProvider.overrideWithValue(testDb),
          secureStorageServiceProvider.overrideWithValue(fakeSecureStorage),
        ],
        child: MaterialApp(
          home: ChatPage(peerId: remotePeerId),
        ),
      ),
    );

    // Let the stream query complete
    await tester.pumpAndSettle();

    // 3. Verify history messages are rendered
    expect(find.text('Hello from past history'), findsOneWidget);
    expect(find.text('My past response'), findsOneWidget);

    // 4. Connect session via secure handshake
    fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
      endpointId: 'QHZD',
      status: ConnectionStatus.connected,
      endpointName: 'QHZD',
    ));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));

    final remoteIdKeyPair = await cryptoService.generateIdentityKeyPair();
    final remoteEphKeyPair = await cryptoService.generateEphemeralKeyPair();
    final remoteIdPub = await remoteIdKeyPair.extractPublicKey();
    final remoteEphPub = await remoteEphKeyPair.extractPublicKey();

    final sigBytes = await cryptoService.signHandshake(
      identityKeyPair: remoteIdKeyPair,
      protocolVersion: kCurrentProtocolVersion,
      peerId: remotePeerId,
      displayName: 'VantraRemotePeer',
      identityPublicKeyBytes: remoteIdPub.bytes,
      ephemeralPublicKeyBytes: remoteEphPub.bytes,
    );

    final remoteHandshake = DomainHandshakePayload(
      protocolVersion: kCurrentProtocolVersion,
      peerId: remotePeerId,
      displayName: 'VantraRemotePeer',
      identityPublicKey: Uint8List.fromList(remoteIdPub.bytes),
      ephemeralPublicKey: Uint8List.fromList(remoteEphPub.bytes),
      signature: Uint8List.fromList(sigBytes),
    );

    fakeTransport.triggerIncomingPayload('QHZD', codec.encodeWireEnvelope(remoteHandshake));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    // Verify Connected banner visible and textfield active
    expect(find.text('Securely Connected'), findsOneWidget);

    // 5. Send new message and verify it appends reactively
    final inputFinder = find.byKey(const Key('chat_input_field'));
    final sendFinder = find.byKey(const Key('chat_send_button'));

    await tester.enterText(inputFinder, 'New real-time message');
    await tester.tap(sendFinder);
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    // Expect to see new message appended alongside old history
    expect(find.text('New real-time message'), findsOneWidget);
    expect(find.text('Hello from past history'), findsOneWidget); // still there

    // Clean up
    await testDb.close();
  });
}
