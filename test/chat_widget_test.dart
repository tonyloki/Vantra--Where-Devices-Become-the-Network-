import 'dart:convert';
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
import 'package:vantra/core/security/crypto_service.dart';
import 'package:vantra/features/messaging/chat_page.dart';
import 'test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
      protocolVersion: 1,
      peerId: remotePeerId,
      displayName: 'RemoteFriend',
      identityPublicKeyBytes: remoteIdPub.bytes,
      ephemeralPublicKeyBytes: remoteEphPub.bytes,
    );

    final remotePayload = {
      'type': 'IDENTITY_SECURE',
      'v': 1,
      'peerId': remotePeerId,
      'displayName': 'RemoteFriend',
      'identityPublicKey': remoteIdPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      'ephemeralPublicKey': remoteEphPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      'signature': sigBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    };

    fakeTransport.triggerIncomingPayload('QHZD', Uint8List.fromList(utf8.encode(jsonEncode(remotePayload))));
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
    final localHandshakeJson = jsonDecode(utf8.decode(fakeTransport.sentPayloads[0])) as Map<String, dynamic>;
    final localEphPubHex = localHandshakeJson['ephemeralPublicKey'] as String;
    final localEphPubBytes = <int>[];
    for (var i = 0; i < localEphPubHex.length; i += 2) {
      localEphPubBytes.add(int.parse(localEphPubHex.substring(i, i + 2), radix: 16));
    }

    final remoteDerivedKeys = await cryptoService.deriveSessionKeys(
      localEphemeralKeyPair: remoteEphKeyPair,
      remoteEphemeralPublicKeyBytes: localEphPubBytes,
    );

    final incomingMessageId = const Uuid().v4();
    final remoteCleartext = jsonEncode({
      'senderId': remotePeerId,
      'receiverId': localPeerId,
      'text': 'Reply from Remote Device',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'seq': 1,
      'sessionId': remoteDerivedKeys.sessionId,
    });

    final encResult = await cryptoService.encryptPayload(
      secretKey: remoteDerivedKeys.sendKey,
      sessionSalt: remoteDerivedKeys.sessionSalt,
      sequence: 1,
      messageId: incomingMessageId,
      plaintextJson: remoteCleartext,
    );

    final incomingPayload = {
      'type': 'ENCRYPTED_TEXT',
      'v': 1,
      'messageId': incomingMessageId,
      'nonce': encResult.nonce.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      'ciphertext': encResult.ciphertext.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      'mac': encResult.mac.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    };

    fakeTransport.triggerIncomingPayload('QHZD', Uint8List.fromList(utf8.encode(jsonEncode(incomingPayload))));
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

    // Verify status and input disabled
    expect(find.text('Disconnected'), findsOneWidget);
    expect(tester.widget<TextField>(inputFinder).enabled, isFalse);
    expect(tester.widget<IconButton>(sendFinder).onPressed, isNull);

    await testDb.close();
  });
}
