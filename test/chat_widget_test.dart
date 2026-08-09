import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:drift/native.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/protocol/protocol_message.dart';
import 'package:vantra/core/protocol/protocol_version.dart';
import 'package:vantra/core/protocol/protobuf_codec.dart';
import 'package:vantra/core/security/crypto_service.dart';
import 'package:vantra/features/messaging/chat_page.dart';
import 'test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = ProtobufCodec();

  testWidgets('ChatPage renders messages, handles text composition, and disables input on disconnect', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final fakeTransport = FakeTransport();
    final remotePeerId = const Uuid().v4();
    final testDb = AppDatabase.forTesting(NativeDatabase.memory());
    final cryptoService = CryptoService();

    final fakeSecureStorage = FakeSecureStorageService();

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

    await tester.pumpAndSettle();

    // Initial state: disconnected, input fields disabled
    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.text('No messages yet'), findsOneWidget);
    expect(find.text('Disconnected'), findsOneWidget);

    final inputFinder = find.byKey(const Key('chat_input_field'));
    final sendFinder = find.byKey(const Key('chat_send_button'));

    expect(tester.widget<TextField>(inputFinder).enabled, isFalse);
    expect(tester.widget<IconButton>(sendFinder).onPressed, isNull);

    // 1. Establish connection via secure handshake
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
      displayName: 'RemoteFriend',
      identityPublicKeyBytes: remoteIdPub.bytes,
      ephemeralPublicKeyBytes: remoteEphPub.bytes,
    );

    final remoteHandshake = DomainHandshakePayload(
      protocolVersion: kCurrentProtocolVersion,
      peerId: remotePeerId,
      displayName: 'RemoteFriend',
      identityPublicKey: Uint8List.fromList(remoteIdPub.bytes),
      ephemeralPublicKey: Uint8List.fromList(remoteEphPub.bytes),
      signature: Uint8List.fromList(sigBytes),
    );

    fakeTransport.triggerIncomingPayload('QHZD', codec.encodeWireEnvelope(remoteHandshake));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    // Verify status changes to Securely Connected
    expect(find.text('Securely Connected'), findsOneWidget);
    expect(tester.widget<TextField>(inputFinder).enabled, isTrue);

    // 2. Type a message and send it
    await tester.enterText(inputFinder, 'Hello from Local Device');
    await tester.tap(sendFinder);
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    // Verify it is displayed in the list
    expect(find.text('Hello from Local Device'), findsOneWidget);

    // 3. Trigger an incoming encrypted text payload from remote
    final localPeerId = prefs.getString('vantra_peer_id') ?? 'me';
    final localHandshake = codec.decodeWireEnvelope(fakeTransport.sentPayloads[0]) as DomainHandshakePayload;

    final remoteDerivedKeys = await cryptoService.deriveSessionKeys(
      localEphemeralKeyPair: remoteEphKeyPair,
      remoteEphemeralPublicKeyBytes: localHandshake.ephemeralPublicKey,
    );

    final incomingMessageId = const Uuid().v4();
    final remotePlaintext = DomainTextMessage(
      messageId: incomingMessageId,
      sessionId: remoteDerivedKeys.sessionId,
      sequence: 1,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      senderId: remotePeerId,
      receiverId: localPeerId,
      content: 'Reply from Remote Device',
    );

    final encResult = await cryptoService.encryptBytes(
      secretKey: remoteDerivedKeys.sendKey,
      sessionSalt: remoteDerivedKeys.sessionSalt,
      sequence: 1,
      messageId: incomingMessageId,
      plaintextBytes: codec.encodePlaintext(remotePlaintext),
    );

    final encWireEnvelope = DomainEncryptedEnvelope(
      protocolVersion: kCurrentProtocolVersion,
      messageId: incomingMessageId,
      sessionId: remoteDerivedKeys.sessionId,
      sequence: 1,
      nonce: Uint8List.fromList(encResult.nonce),
      ciphertext: Uint8List.fromList(encResult.ciphertext),
      mac: Uint8List.fromList(encResult.mac),
    );

    fakeTransport.triggerIncomingPayload('QHZD', codec.encodeWireEnvelope(encWireEnvelope));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    // Verify remote message is displayed
    expect(find.text('Reply from Remote Device'), findsOneWidget);

    // 4. Trigger disconnection
    fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
      endpointId: 'QHZD',
      status: ConnectionStatus.disconnected,
      endpointName: 'QHZD',
    ));
    await tester.pumpAndSettle();

    expect(find.text('Disconnected'), findsOneWidget);
    expect(tester.widget<TextField>(inputFinder).enabled, isFalse);
    expect(find.text('Hello from Local Device'), findsOneWidget);
    expect(find.text('Reply from Remote Device'), findsOneWidget);

    await testDb.close();
  });
}
