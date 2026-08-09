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
import 'package:vantra/core/security/crypto_service.dart';
import 'test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeTransport fakeTransport;
  late ProviderContainer container;
  late AppDatabase testDb;
  late CryptoService cryptoService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    fakeTransport = FakeTransport();
    testDb = AppDatabase.forTesting(NativeDatabase.memory());
    cryptoService = CryptoService();

    final fakeSecureStorage = FakeSecureStorageService();
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        transportProvider.overrideWithValue(fakeTransport),
        appDatabaseProvider.overrideWithValue(testDb),
        secureStorageServiceProvider.overrideWithValue(fakeSecureStorage),
      ],
    );

    await container.read(localIdentityStateProvider.notifier).ensureKeysLoaded();
  });

  tearDown(() async {
    await testDb.close();
    container.dispose();
  });

  group('Encrypted Messaging Pipeline & Replay Tests', () {
    test('End-to-end encrypted sending, receiving, and replay protection', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      container.read(messagingStateProvider);

      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'QHZD',
        status: ConnectionStatus.connected,
        endpointName: 'QHZD',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      // 1. Establish handshake
      final remoteIdentityKeyPair = await cryptoService.generateIdentityKeyPair();
      final remoteEphemeralKeyPair = await cryptoService.generateEphemeralKeyPair();
      final remoteIdPub = await remoteIdentityKeyPair.extractPublicKey();
      final remoteEphPub = await remoteEphemeralKeyPair.extractPublicKey();
      final remotePeerId = const Uuid().v4();

      final sigBytes = await cryptoService.signHandshake(
        identityKeyPair: remoteIdentityKeyPair,
        protocolVersion: 1,
        peerId: remotePeerId,
        displayName: 'RemoteSecurePeer',
        identityPublicKeyBytes: remoteIdPub.bytes,
        ephemeralPublicKeyBytes: remoteEphPub.bytes,
      );

      final hexSig = sigBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final hexIdPub = remoteIdPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final hexEphPub = remoteEphPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      final handshakePayload = {
        'type': 'IDENTITY_SECURE',
        'v': 1,
        'peerId': remotePeerId,
        'displayName': 'RemoteSecurePeer',
        'identityPublicKey': hexIdPub,
        'ephemeralPublicKey': hexEphPub,
        'signature': hexSig,
      };

      fakeTransport.triggerIncomingPayload('QHZD', Uint8List.fromList(utf8.encode(jsonEncode(handshakePayload))));
      await Future.delayed(const Duration(milliseconds: 50));

      // 2. Send outgoing encrypted message
      await notifier.sendTextMessage(remotePeerId, 'Secret payload from local');

      // Verify payload sent over transport is encrypted
      expect(fakeTransport.sentPayloads.length, 2);
      final sentTextJson = jsonDecode(utf8.decode(fakeTransport.sentPayloads[1])) as Map<String, dynamic>;
      expect(sentTextJson['type'], 'ENCRYPTED_TEXT');
      expect(sentTextJson['v'], 1);
      expect(sentTextJson['ciphertext'], isNotNull);
      expect(sentTextJson['nonce'], isNotNull);
      expect(sentTextJson['mac'], isNotNull);

      // Verify stored locally as sent
      final localIdentity = container.read(localIdentityStateProvider);
      final repo = container.read(messagingRepositoryProvider);
      var conv = await repo.getConversation(localIdentity.peerId, remotePeerId);
      expect(conv.length, 1);
      expect(conv[0].text, 'Secret payload from local');
      expect(conv[0].status, MessageStatus.sent);

      // 3. Receive incoming encrypted message from remote peer
      // Extract local ephemeral public key from sent handshake
      final localHandshakeJson = jsonDecode(utf8.decode(fakeTransport.sentPayloads[0])) as Map<String, dynamic>;
      final localEphPubHex = localHandshakeJson['ephemeralPublicKey'] as String;
      final localEphPubBytes = <int>[];
      for (var i = 0; i < localEphPubHex.length; i += 2) {
        localEphPubBytes.add(int.parse(localEphPubHex.substring(i, i + 2), radix: 16));
      }

      final remoteDerivedKeys = await cryptoService.deriveSessionKeys(
        localEphemeralKeyPair: remoteEphemeralKeyPair,
        remoteEphemeralPublicKeyBytes: localEphPubBytes,
      );

      final incomingMessageId = const Uuid().v4();
      final remoteCleartext = jsonEncode({
        'senderId': remotePeerId,
        'receiverId': localIdentity.peerId,
        'text': 'Reply secret from remote',
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

      final encPayload = {
        'type': 'ENCRYPTED_TEXT',
        'v': 1,
        'messageId': incomingMessageId,
        'nonce': encResult.nonce.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        'ciphertext': encResult.ciphertext.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        'mac': encResult.mac.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      };

      fakeTransport.triggerIncomingPayload('QHZD', Uint8List.fromList(utf8.encode(jsonEncode(encPayload))));
      await Future.delayed(const Duration(milliseconds: 50));

      // Verify decrypted and saved to SQLite
      conv = await repo.getConversation(localIdentity.peerId, remotePeerId);
      expect(conv.length, 2);
      expect(conv[1].text, 'Reply secret from remote');
      expect(conv[1].status, MessageStatus.received);

      // 4. Replay attack test: transmit same packet again
      fakeTransport.triggerIncomingPayload('QHZD', Uint8List.fromList(utf8.encode(jsonEncode(encPayload))));
      await Future.delayed(const Duration(milliseconds: 50));

      // Must remain 2 messages (replay rejected)
      conv = await repo.getConversation(localIdentity.peerId, remotePeerId);
      expect(conv.length, 2);
    });

    test('Bidirectional symmetry: local device decrypts remote messages whether it is Device A or Device B', () async {
      container.read(messagingStateProvider);

      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'PEER_X',
        status: ConnectionStatus.connected,
        endpointName: 'PEER_X',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      final remoteIdentityKeyPair = await cryptoService.generateIdentityKeyPair();
      final remoteEphemeralKeyPair = await cryptoService.generateEphemeralKeyPair();
      final remoteIdPub = await remoteIdentityKeyPair.extractPublicKey();
      final remoteEphPub = await remoteEphemeralKeyPair.extractPublicKey();
      final remotePeerId = const Uuid().v4();

      final sigBytes = await cryptoService.signHandshake(
        identityKeyPair: remoteIdentityKeyPair,
        protocolVersion: 1,
        peerId: remotePeerId,
        displayName: 'PeerX',
        identityPublicKeyBytes: remoteIdPub.bytes,
        ephemeralPublicKeyBytes: remoteEphPub.bytes,
      );

      final handshakePayload = {
        'type': 'IDENTITY_SECURE',
        'v': 1,
        'peerId': remotePeerId,
        'displayName': 'PeerX',
        'identityPublicKey': remoteIdPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        'ephemeralPublicKey': remoteEphPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        'signature': sigBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      };

      fakeTransport.triggerIncomingPayload('PEER_X', Uint8List.fromList(utf8.encode(jsonEncode(handshakePayload))));
      await Future.delayed(const Duration(milliseconds: 50));

      // Extract local ephemeral public key from sent handshake
      final localHandshakeJson = jsonDecode(utf8.decode(fakeTransport.sentPayloads[0])) as Map<String, dynamic>;
      final localEphPubHex = localHandshakeJson['ephemeralPublicKey'] as String;
      final localEphPubBytes = <int>[];
      for (var i = 0; i < localEphPubHex.length; i += 2) {
        localEphPubBytes.add(int.parse(localEphPubHex.substring(i, i + 2), radix: 16));
      }

      // Remote derives keys
      final remoteDerivedKeys = await cryptoService.deriveSessionKeys(
        localEphemeralKeyPair: remoteEphemeralKeyPair,
        remoteEphemeralPublicKeyBytes: localEphPubBytes,
      );

      final localIdentity = container.read(localIdentityStateProvider);
      final repo = container.read(messagingRepositoryProvider);

      // Remote sends message to Local
      final incomingMessageId = const Uuid().v4();
      final remoteCleartext = jsonEncode({
        'senderId': remotePeerId,
        'receiverId': localIdentity.peerId,
        'text': 'Bidirectional test message',
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

      final encPayload = {
        'type': 'ENCRYPTED_TEXT',
        'v': 1,
        'messageId': incomingMessageId,
        'nonce': encResult.nonce.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        'ciphertext': encResult.ciphertext.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        'mac': encResult.mac.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      };

      fakeTransport.triggerIncomingPayload('PEER_X', Uint8List.fromList(utf8.encode(jsonEncode(encPayload))));
      await Future.delayed(const Duration(milliseconds: 50));

      final conv = await repo.getConversation(localIdentity.peerId, remotePeerId);
      expect(conv.length, 1);
      expect(conv[0].text, 'Bidirectional test message');
      expect(conv[0].status, MessageStatus.received);
    });
  });
}
