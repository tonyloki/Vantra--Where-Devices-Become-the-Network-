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
import 'package:vantra/core/models/peer_session.dart';
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

    // Ensure local identity cryptographic keys are generated
    await container.read(localIdentityStateProvider.notifier).ensureKeysLoaded();
  });

  tearDown(() async {
    await testDb.close();
    container.dispose();
  });

  group('Secure Handshake Protocol Tests', () {
    test('Connection trigger sends IDENTITY_SECURE packet', () async {
      container.read(messagingStateProvider);

      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'QHZD',
        status: ConnectionStatus.connected,
        endpointName: 'QHZD',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      expect(fakeTransport.sentPayloads.length, 1);
      final json = jsonDecode(utf8.decode(fakeTransport.sentPayloads[0])) as Map<String, dynamic>;
      expect(json['type'], 'IDENTITY_SECURE');
      expect(json['v'], 1);
      expect(json['signature'], isNotNull);
    });

    test('Valid remote handshake establishes secure session', () async {
      container.read(messagingStateProvider);

      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'QHZD',
        status: ConnectionStatus.connected,
        endpointName: 'QHZD',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      // Simulate remote peer keypair
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

      final state = container.read(messagingStateProvider);
      final session = state.sessions[remotePeerId];

      expect(session, isNotNull);
      expect(session!.isSecure, isTrue);
      expect(session.status, SessionStatus.connected);
      expect(session.fingerprint, isNotNull);
    });

    test('Tampered handshake signature causes immediate disconnect', () async {
      container.read(messagingStateProvider);

      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'QHZD',
        status: ConnectionStatus.connected,
        endpointName: 'QHZD',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      final remoteIdentityKeyPair = await cryptoService.generateIdentityKeyPair();
      final remoteEphemeralKeyPair = await cryptoService.generateEphemeralKeyPair();

      final remoteIdPub = await remoteIdentityKeyPair.extractPublicKey();
      final remoteEphPub = await remoteEphemeralKeyPair.extractPublicKey();
      final remotePeerId = const Uuid().v4();

      // Sign with valid data
      final sigBytes = await cryptoService.signHandshake(
        identityKeyPair: remoteIdentityKeyPair,
        protocolVersion: 1,
        peerId: remotePeerId,
        displayName: 'LegitName',
        identityPublicKeyBytes: remoteIdPub.bytes,
        ephemeralPublicKeyBytes: remoteEphPub.bytes,
      );

      final hexSig = sigBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final hexIdPub = remoteIdPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final hexEphPub = remoteEphPub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      // Transmit with tampered displayName so signature check fails
      final tamperedHandshake = {
        'type': 'IDENTITY_SECURE',
        'v': 1,
        'peerId': remotePeerId,
        'displayName': 'TamperedName',
        'identityPublicKey': hexIdPub,
        'ephemeralPublicKey': hexEphPub,
        'signature': hexSig,
      };

      fakeTransport.triggerIncomingPayload('QHZD', Uint8List.fromList(utf8.encode(jsonEncode(tamperedHandshake))));
      await Future.delayed(const Duration(milliseconds: 50));

      // Disconnect must have been called
      expect(fakeTransport.disconnectCalled, isTrue);
      expect(fakeTransport.disconnectedTarget, 'QHZD');
    });
  });
}
