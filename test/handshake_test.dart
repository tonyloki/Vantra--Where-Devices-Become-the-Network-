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
import 'package:vantra/core/protocol/protocol_message.dart';
import 'package:vantra/core/protocol/protocol_version.dart';
import 'package:vantra/core/protocol/protobuf_codec.dart';
import 'package:vantra/core/security/crypto_service.dart';
import 'test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeTransport fakeTransport;
  late ProviderContainer container;
  late AppDatabase testDb;
  late CryptoService cryptoService;
  const codec = ProtobufCodec();

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

  group('Secure Handshake Protocol Tests (Protobuf Wire)', () {
    test('Connection trigger sends IDENTITY_SECURE protobuf packet', () async {
      container.read(messagingStateProvider);

      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'QHZD',
        status: ConnectionStatus.connected,
        endpointName: 'QHZD',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      expect(fakeTransport.sentPayloads.length, 1);
      final envelope = codec.decodeWireEnvelope(fakeTransport.sentPayloads[0]);
      expect(envelope, isA<DomainHandshakePayload>());
      final handshake = envelope as DomainHandshakePayload;
      expect(handshake.protocolVersion, kCurrentProtocolVersion);
      expect(handshake.maxSupportedVersion, kCurrentProtocolVersion);
      expect(handshake.signature.length, 64);
      expect(handshake.identityPublicKey.length, 32);
      expect(handshake.ephemeralPublicKey.length, 32);
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
        protocolVersion: kCurrentProtocolVersion,
        peerId: remotePeerId,
        displayName: 'RemoteSecurePeer',
        identityPublicKeyBytes: remoteIdPub.bytes,
        ephemeralPublicKeyBytes: remoteEphPub.bytes,
      );

      final handshakePayload = DomainHandshakePayload(
        protocolVersion: kCurrentProtocolVersion,
        peerId: remotePeerId,
        displayName: 'RemoteSecurePeer',
        identityPublicKey: Uint8List.fromList(remoteIdPub.bytes),
        ephemeralPublicKey: Uint8List.fromList(remoteEphPub.bytes),
        signature: Uint8List.fromList(sigBytes),
      );

      fakeTransport.triggerIncomingPayload('QHZD', codec.encodeWireEnvelope(handshakePayload));
      await Future.delayed(const Duration(milliseconds: 50));

      final state = container.read(messagingStateProvider);
      final session = state.sessions[remotePeerId];

      expect(session, isNotNull);
      expect(session!.isSecure, isTrue);
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
        protocolVersion: kCurrentProtocolVersion,
        peerId: remotePeerId,
        displayName: 'LegitName',
        identityPublicKeyBytes: remoteIdPub.bytes,
        ephemeralPublicKeyBytes: remoteEphPub.bytes,
      );

      // Transmit with tampered displayName so signature check fails
      final tamperedHandshake = DomainHandshakePayload(
        protocolVersion: kCurrentProtocolVersion,
        peerId: remotePeerId,
        displayName: 'TamperedName',
        identityPublicKey: Uint8List.fromList(remoteIdPub.bytes),
        ephemeralPublicKey: Uint8List.fromList(remoteEphPub.bytes),
        signature: Uint8List.fromList(sigBytes),
      );

      fakeTransport.triggerIncomingPayload('QHZD', codec.encodeWireEnvelope(tamperedHandshake));
      await Future.delayed(const Duration(milliseconds: 50));

      // Disconnect must have been called
      expect(fakeTransport.disconnectCalled, isTrue);
      expect(fakeTransport.disconnectedTarget, 'QHZD');
    });

    test('Duplicate handshake payloads are ignored on active connection', () async {
      container.read(messagingStateProvider);

      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'QHZD',
        status: ConnectionStatus.connected,
        endpointName: 'Name:some-peer-id',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      final remoteIdentityKeyPair = await cryptoService.generateIdentityKeyPair();
      final remoteEphemeralKeyPair = await cryptoService.generateEphemeralKeyPair();

      final remoteIdPub = await remoteIdentityKeyPair.extractPublicKey();
      final remoteEphPub = await remoteEphemeralKeyPair.extractPublicKey();
      final remotePeerId = 'some-peer-id';

      final sigBytes = await cryptoService.signHandshake(
        identityKeyPair: remoteIdentityKeyPair,
        protocolVersion: 1,
        peerId: remotePeerId,
        displayName: 'Name',
        identityPublicKeyBytes: remoteIdPub.bytes,
        ephemeralPublicKeyBytes: remoteEphPub.bytes,
      );

      final handshakePayload = DomainHandshakePayload(
        protocolVersion: 1, // V1 wire version
        peerId: remotePeerId,
        displayName: 'Name',
        identityPublicKey: Uint8List.fromList(remoteIdPub.bytes),
        ephemeralPublicKey: Uint8List.fromList(remoteEphPub.bytes),
        signature: Uint8List.fromList(sigBytes),
      );

      // Trigger first handshake
      fakeTransport.triggerIncomingPayload('QHZD', codec.encodeWireEnvelope(handshakePayload));
      await Future.delayed(const Duration(milliseconds: 50));

      var state = container.read(messagingStateProvider);
      var session = state.sessions[remotePeerId];
      expect(session, isNotNull);
      expect(session!.status, SessionStatus.connected); // V1 sets connected directly

      // Reset disconnectCalled tracking
      fakeTransport.disconnectCalled = false;

      // Trigger duplicate handshake
      fakeTransport.triggerIncomingPayload('QHZD', codec.encodeWireEnvelope(handshakePayload));
      await Future.delayed(const Duration(milliseconds: 50));

      // Verify no disconnect was triggered and session remains active
      expect(fakeTransport.disconnectCalled, isFalse);
      state = container.read(messagingStateProvider);
      session = state.sessions[remotePeerId];
      expect(session!.status, SessionStatus.connected);
    });

    test('Disconnected state cleanup removes active connection lock using candidatePeerId fallback', () async {
      final notifier = container.read(messagingStateProvider.notifier);

      // Artificially lock the peerId
      notifier.activeConnectLocks.add('some-peer-id');
      expect(notifier.activeConnectLocks.contains('some-peer-id'), isTrue);

      // Simulate a disconnected event with endpointName formatted as Name:PeerId
      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'QHZD',
        status: ConnectionStatus.disconnected,
        endpointName: 'Name:some-peer-id',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      // Lock must be cleared
      expect(notifier.activeConnectLocks.contains('some-peer-id'), isFalse);
    });

    test('Endpoint to PeerId mapping is populated immediately upon CONNECTED', () async {
      container.read(messagingStateProvider);

      fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
        endpointId: 'QHZD',
        status: ConnectionStatus.connected,
        endpointName: 'TestName:immediate-peer-id',
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      final state = container.read(messagingStateProvider);
      expect(state.endpointToPeerId['QHZD'], equals('immediate-peer-id'));
      expect(state.sessions['immediate-peer-id'], isNotNull);
      expect(state.sessions['immediate-peer-id']!.endpointId, equals('QHZD'));
    });
  });
}
