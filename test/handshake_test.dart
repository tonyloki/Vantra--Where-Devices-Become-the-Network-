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
import 'package:cryptography/cryptography.dart';
import 'package:vantra/core/security/security_session.dart';
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

    testWidgets('Watchdog regression test: initial handshake and capability watchdog lifecycle', (WidgetTester tester) async {
      await tester.runAsync(() async {
        // Set up fresh mock context
        final mockTransport = FakeTransport();
        final mockDb = AppDatabase.forTesting(NativeDatabase.memory());
        final mockCrypto = CryptoService();
        final mockSecureStorage = FakeSecureStorageService();
        final mockPrefs = await SharedPreferences.getInstance();

        final mockContainer = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(mockPrefs),
            transportProvider.overrideWithValue(mockTransport),
            appDatabaseProvider.overrideWithValue(mockDb),
            secureStorageServiceProvider.overrideWithValue(mockSecureStorage),
          ],
        );
        addTearDown(() async {
          await mockDb.close();
          mockContainer.dispose();
        });

        await mockContainer.read(localIdentityStateProvider.notifier).ensureKeysLoaded();
        final notifier = mockContainer.read(messagingStateProvider.notifier);

        // Configure watchdog timers for testing: initial handshake is short (200ms), capability watchdog is longer (2s)
        notifier.handshakeWatchdogDuration = const Duration(milliseconds: 200);
        notifier.capabilityWatchdogDuration = const Duration(seconds: 2);

        // 1. CONNECTED arms initial watchdog.
        mockTransport.triggerConnectionUpdate(const ConnectionUpdate(
          endpointId: 'QHZD',
          status: ConnectionStatus.connected,
          endpointName: 'RemotePeer:remote-peer-uuid',
        ));
        await Future.delayed(const Duration(milliseconds: 50));

        expect(notifier.handshakeTimers.containsKey('QHZD'), isTrue);
        expect(notifier.capabilityWatchdogTimers.containsKey('QHZD'), isFalse);

        // 2. KEY_DERIVED registers secure session.
        final remoteIdentityKeyPair = await mockCrypto.generateIdentityKeyPair();
        final remoteEphemeralKeyPair = await mockCrypto.generateEphemeralKeyPair();
        final remoteIdPub = await remoteIdentityKeyPair.extractPublicKey();
        final remoteEphPub = await remoteEphemeralKeyPair.extractPublicKey();
        final remotePeerId = 'remote-peer-uuid';

        final sigBytes = await mockCrypto.signHandshake(
          identityKeyPair: remoteIdentityKeyPair,
          protocolVersion: kCurrentProtocolVersion,
          peerId: remotePeerId,
          displayName: 'RemotePeer',
          identityPublicKeyBytes: remoteIdPub.bytes,
          ephemeralPublicKeyBytes: remoteEphPub.bytes,
        );

        final handshakePayload = DomainHandshakePayload(
          protocolVersion: kCurrentProtocolVersion,
          peerId: remotePeerId,
          displayName: 'RemotePeer',
          identityPublicKey: Uint8List.fromList(remoteIdPub.bytes),
          ephemeralPublicKey: Uint8List.fromList(remoteEphPub.bytes),
          signature: Uint8List.fromList(sigBytes),
          minSupportedVersion: 2,
          maxSupportedVersion: 2,
        );

        // Trigger handshake payload (key derivation)
        mockTransport.triggerIncomingPayload('QHZD', codec.encodeWireEnvelope(handshakePayload));
        await Future.delayed(const Duration(milliseconds: 100));

        // 3. Initial watchdog is cancelled.
        // 4. Capability watchdog is started.
        expect(notifier.handshakeTimers.containsKey('QHZD'), isFalse);
        expect(notifier.capabilityWatchdogTimers.containsKey('QHZD'), isTrue);
        expect(notifier.securitySessions[remotePeerId], isNotNull);

        // 5. Advancing beyond the original watchdog duration (200ms) does NOT disconnect.
        await Future.delayed(const Duration(milliseconds: 250));
        expect(mockTransport.disconnectCalled, isFalse);

        // 6. Successful CapabilitiesExchange cancels capability watchdog.
        final secSession = notifier.securitySessions[remotePeerId]!;
        final capabilitiesPayload = DomainCapabilitiesExchange(
          messageId: const Uuid().v4(),
          sessionId: secSession.sessionId,
          sequence: 1,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          senderId: remotePeerId,
          receiverId: mockContainer.read(localIdentityStateProvider).peerId,
          minSupportedVersion: 2,
          maxSupportedVersion: 2,
          supportedCapabilities: const [VantraCapability.text],
        );

        final encBytes = await mockCrypto.encryptBytes(
          secretKey: secSession.receiveKey,
          sessionSalt: secSession.sessionSalt,
          sequence: 1,
          messageId: capabilitiesPayload.messageId,
          plaintextBytes: codec.encodePlaintext(capabilitiesPayload),
        );

        final encryptedEnvelope = DomainEncryptedEnvelope(
          protocolVersion: kCurrentProtocolVersion,
          messageId: capabilitiesPayload.messageId,
          sessionId: secSession.sessionId,
          sequence: 1,
          nonce: Uint8List.fromList(encBytes.nonce),
          ciphertext: Uint8List.fromList(encBytes.ciphertext),
          mac: Uint8List.fromList(encBytes.mac),
        );

        mockTransport.triggerIncomingPayload('QHZD', codec.encodeWireEnvelope(encryptedEnvelope));
        await Future.delayed(const Duration(milliseconds: 100));

        // Watchdog must be cancelled
        expect(notifier.capabilityWatchdogTimers.containsKey('QHZD'), isFalse);
        expect(mockContainer.read(messagingStateProvider).sessions[remotePeerId]!.status, equals(SessionStatus.connected));

        // 7. Advancing beyond capability watchdog after successful negotiation does NOT disconnect.
        await Future.delayed(const Duration(milliseconds: 2500));
        expect(mockTransport.disconnectCalled, isFalse);
      });
    });

    testWidgets('Watchdog regression test: capability watchdog timeout performs cleanup', (WidgetTester tester) async {
      await tester.runAsync(() async {
        final mockTransport = FakeTransport();
        final mockDb = AppDatabase.forTesting(NativeDatabase.memory());
        final mockCrypto = CryptoService();
        final mockSecureStorage = FakeSecureStorageService();
        final mockPrefs = await SharedPreferences.getInstance();

        final mockContainer = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(mockPrefs),
            transportProvider.overrideWithValue(mockTransport),
            appDatabaseProvider.overrideWithValue(mockDb),
            secureStorageServiceProvider.overrideWithValue(mockSecureStorage),
          ],
        );
        addTearDown(() async {
          await mockDb.close();
          mockContainer.dispose();
        });

        await mockContainer.read(localIdentityStateProvider.notifier).ensureKeysLoaded();
        final notifier = mockContainer.read(messagingStateProvider.notifier);

        // For this test, initial handshake watchdog is long (5s), capability watchdog is short (200ms)
        notifier.handshakeWatchdogDuration = const Duration(seconds: 5);
        notifier.capabilityWatchdogDuration = const Duration(milliseconds: 200);

        mockTransport.triggerConnectionUpdate(const ConnectionUpdate(
          endpointId: 'QHZD',
          status: ConnectionStatus.connected,
          endpointName: 'RemotePeer:remote-peer-uuid',
        ));
        await Future.delayed(const Duration(milliseconds: 50));

        final remoteIdentityKeyPair = await mockCrypto.generateIdentityKeyPair();
        final remoteEphemeralKeyPair = await mockCrypto.generateEphemeralKeyPair();
        final remoteIdPub = await remoteIdentityKeyPair.extractPublicKey();
        final remoteEphPub = await remoteEphemeralKeyPair.extractPublicKey();
        final remotePeerId = 'remote-peer-uuid';

        final sigBytes = await mockCrypto.signHandshake(
          identityKeyPair: remoteIdentityKeyPair,
          protocolVersion: kCurrentProtocolVersion,
          peerId: remotePeerId,
          displayName: 'RemotePeer',
          identityPublicKeyBytes: remoteIdPub.bytes,
          ephemeralPublicKeyBytes: remoteEphPub.bytes,
        );

        final handshakePayload = DomainHandshakePayload(
          protocolVersion: kCurrentProtocolVersion,
          peerId: remotePeerId,
          displayName: 'RemotePeer',
          identityPublicKey: Uint8List.fromList(remoteIdPub.bytes),
          ephemeralPublicKey: Uint8List.fromList(remoteEphPub.bytes),
          signature: Uint8List.fromList(sigBytes),
          minSupportedVersion: 2,
          maxSupportedVersion: 2,
        );

        mockTransport.triggerIncomingPayload('QHZD', codec.encodeWireEnvelope(handshakePayload));
        await Future.delayed(const Duration(milliseconds: 100));

        expect(notifier.capabilityWatchdogTimers.containsKey('QHZD'), isTrue);

        // 8. Capability timeout before negotiation still performs the expected cleanup (disconnects QHZD)
        await Future.delayed(const Duration(milliseconds: 250));
        expect(mockTransport.disconnectCalled, isTrue);
        expect(mockTransport.disconnectedTarget, equals('QHZD'));
        expect(notifier.securitySessions[remotePeerId], isNull);
      });
    });

    testWidgets('Watchdog regression test A: SESSION_DERIVED alone does NOT cancel the initial watchdog', (WidgetTester tester) async {
      await tester.runAsync(() async {
        final mockTransport = FakeTransport();
        final mockDb = AppDatabase.forTesting(NativeDatabase.memory());
        final mockCrypto = DelayedCryptoService(delay: const Duration(milliseconds: 300));
        final mockSecureStorage = FakeSecureStorageService();
        final mockPrefs = await SharedPreferences.getInstance();

        final mockContainer = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(mockPrefs),
            transportProvider.overrideWithValue(mockTransport),
            appDatabaseProvider.overrideWithValue(mockDb),
            secureStorageServiceProvider.overrideWithValue(mockSecureStorage),
            cryptoServiceProvider.overrideWithValue(mockCrypto),
          ],
        );
        addTearDown(() async {
          await mockDb.close();
          mockContainer.dispose();
        });

        await mockContainer.read(localIdentityStateProvider.notifier).ensureKeysLoaded();
        final notifier = mockContainer.read(messagingStateProvider.notifier);

        notifier.handshakeWatchdogDuration = const Duration(milliseconds: 150);

        mockTransport.triggerConnectionUpdate(const ConnectionUpdate(
          endpointId: 'QHZD',
          status: ConnectionStatus.connected,
          endpointName: 'RemotePeer:remote-peer-uuid',
        ));
        await Future.delayed(const Duration(milliseconds: 50));

        final remoteIdentityKeyPair = await mockCrypto.generateIdentityKeyPair();
        final remoteEphemeralKeyPair = await mockCrypto.generateEphemeralKeyPair();
        final remoteIdPub = await remoteIdentityKeyPair.extractPublicKey();
        final remoteEphPub = await remoteEphemeralKeyPair.extractPublicKey();
        final remotePeerId = 'remote-peer-uuid';

        final sigBytes = await mockCrypto.signHandshake(
          identityKeyPair: remoteIdentityKeyPair,
          protocolVersion: kCurrentProtocolVersion,
          peerId: remotePeerId,
          displayName: 'RemotePeer',
          identityPublicKeyBytes: remoteIdPub.bytes,
          ephemeralPublicKeyBytes: remoteEphPub.bytes,
        );

        final handshakePayload = DomainHandshakePayload(
          protocolVersion: kCurrentProtocolVersion,
          peerId: remotePeerId,
          displayName: 'RemotePeer',
          identityPublicKey: Uint8List.fromList(remoteIdPub.bytes),
          ephemeralPublicKey: Uint8List.fromList(remoteEphPub.bytes),
          signature: Uint8List.fromList(sigBytes),
          minSupportedVersion: 2,
          maxSupportedVersion: 2,
        );

        mockTransport.triggerIncomingPayload('QHZD', codec.encodeWireEnvelope(handshakePayload));
        
        // Wait 100ms. Key derivation completes (logging SESSION_DERIVED), but Double Ratchet takes 300ms.
        await Future.delayed(const Duration(milliseconds: 100));
        
        // The watchdog is still active.
        expect(notifier.handshakeTimers.containsKey('QHZD'), isTrue);

        // Wait another 100ms (total 200ms). The 150ms watchdog should fire and disconnect.
        await Future.delayed(const Duration(milliseconds: 100));
        expect(mockTransport.disconnectCalled, isTrue);
        expect(mockTransport.disconnectedTarget, equals('QHZD'));
      });
    });

    testWidgets('Watchdog regression test B: Successful Double Ratchet init cancels the watchdog', (WidgetTester tester) async {
      await tester.runAsync(() async {
        final mockTransport = FakeTransport();
        final mockDb = AppDatabase.forTesting(NativeDatabase.memory());
        final mockCrypto = CryptoService();
        final mockSecureStorage = FakeSecureStorageService();
        final mockPrefs = await SharedPreferences.getInstance();

        final mockContainer = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(mockPrefs),
            transportProvider.overrideWithValue(mockTransport),
            appDatabaseProvider.overrideWithValue(mockDb),
            secureStorageServiceProvider.overrideWithValue(mockSecureStorage),
            cryptoServiceProvider.overrideWithValue(mockCrypto),
          ],
        );
        addTearDown(() async {
          await mockDb.close();
          mockContainer.dispose();
        });

        await mockContainer.read(localIdentityStateProvider.notifier).ensureKeysLoaded();
        final notifier = mockContainer.read(messagingStateProvider.notifier);

        notifier.handshakeWatchdogDuration = const Duration(milliseconds: 500);

        mockTransport.triggerConnectionUpdate(const ConnectionUpdate(
          endpointId: 'QHZD',
          status: ConnectionStatus.connected,
          endpointName: 'RemotePeer:remote-peer-uuid',
        ));
        await Future.delayed(const Duration(milliseconds: 50));

        final remoteIdentityKeyPair = await mockCrypto.generateIdentityKeyPair();
        final remoteEphemeralKeyPair = await mockCrypto.generateEphemeralKeyPair();
        final remoteIdPub = await remoteIdentityKeyPair.extractPublicKey();
        final remoteEphPub = await remoteEphemeralKeyPair.extractPublicKey();
        final remotePeerId = 'remote-peer-uuid';

        final sigBytes = await mockCrypto.signHandshake(
          identityKeyPair: remoteIdentityKeyPair,
          protocolVersion: kCurrentProtocolVersion,
          peerId: remotePeerId,
          displayName: 'RemotePeer',
          identityPublicKeyBytes: remoteIdPub.bytes,
          ephemeralPublicKeyBytes: remoteEphPub.bytes,
        );

        final handshakePayload = DomainHandshakePayload(
          protocolVersion: kCurrentProtocolVersion,
          peerId: remotePeerId,
          displayName: 'RemotePeer',
          identityPublicKey: Uint8List.fromList(remoteIdPub.bytes),
          ephemeralPublicKey: Uint8List.fromList(remoteEphPub.bytes),
          signature: Uint8List.fromList(sigBytes),
          minSupportedVersion: 2,
          maxSupportedVersion: 2,
        );

        mockTransport.triggerIncomingPayload('QHZD', codec.encodeWireEnvelope(handshakePayload));
        await Future.delayed(const Duration(milliseconds: 150));

        // Watchdog should be cancelled
        expect(notifier.handshakeTimers.containsKey('QHZD'), isFalse);
        expect(notifier.securitySessions[remotePeerId], isNotNull);

        // Advance beyond watchdog duration and verify no disconnect occurs
        await Future.delayed(const Duration(milliseconds: 400));
        expect(mockTransport.disconnectCalled, isFalse);
      });
    });

    testWidgets('Watchdog regression test C: Double Ratchet failure is visible and cleans up', (WidgetTester tester) async {
      await tester.runAsync(() async {
        final mockTransport = FakeTransport();
        final mockDb = AppDatabase.forTesting(NativeDatabase.memory());
        final mockCrypto = FailingCryptoService();
        final mockSecureStorage = FakeSecureStorageService();
        final mockPrefs = await SharedPreferences.getInstance();

        final mockContainer = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(mockPrefs),
            transportProvider.overrideWithValue(mockTransport),
            appDatabaseProvider.overrideWithValue(mockDb),
            secureStorageServiceProvider.overrideWithValue(mockSecureStorage),
            cryptoServiceProvider.overrideWithValue(mockCrypto),
          ],
        );
        addTearDown(() async {
          await mockDb.close();
          mockContainer.dispose();
        });

        await mockContainer.read(localIdentityStateProvider.notifier).ensureKeysLoaded();
        final notifier = mockContainer.read(messagingStateProvider.notifier);

        mockTransport.triggerConnectionUpdate(const ConnectionUpdate(
          endpointId: 'QHZD',
          status: ConnectionStatus.connected,
          endpointName: 'RemotePeer:remote-peer-uuid',
        ));
        await Future.delayed(const Duration(milliseconds: 50));

        final remoteIdentityKeyPair = await mockCrypto.generateIdentityKeyPair();
        final remoteEphemeralKeyPair = await mockCrypto.generateEphemeralKeyPair();
        final remoteIdPub = await remoteIdentityKeyPair.extractPublicKey();
        final remoteEphPub = await remoteEphemeralKeyPair.extractPublicKey();
        final remotePeerId = 'remote-peer-uuid';

        final sigBytes = await mockCrypto.signHandshake(
          identityKeyPair: remoteIdentityKeyPair,
          protocolVersion: kCurrentProtocolVersion,
          peerId: remotePeerId,
          displayName: 'RemotePeer',
          identityPublicKeyBytes: remoteIdPub.bytes,
          ephemeralPublicKeyBytes: remoteEphPub.bytes,
        );

        final handshakePayload = DomainHandshakePayload(
          protocolVersion: kCurrentProtocolVersion,
          peerId: remotePeerId,
          displayName: 'RemotePeer',
          identityPublicKey: Uint8List.fromList(remoteIdPub.bytes),
          ephemeralPublicKey: Uint8List.fromList(remoteEphPub.bytes),
          signature: Uint8List.fromList(sigBytes),
          minSupportedVersion: 2,
          maxSupportedVersion: 2,
        );

        mockTransport.triggerIncomingPayload('QHZD', codec.encodeWireEnvelope(handshakePayload));
        await Future.delayed(const Duration(milliseconds: 100));

        // Should clean up and disconnect immediately
        expect(mockTransport.disconnectCalled, isTrue);
        expect(mockTransport.disconnectedTarget, equals('QHZD'));
        expect(notifier.securitySessions[remotePeerId], isNull);
      });
    });

    testWidgets('Watchdog regression test D: Secure registered session cannot be destroyed by stale watchdog', (WidgetTester tester) async {
      await tester.runAsync(() async {
        final mockTransport = FakeTransport();
        final mockDb = AppDatabase.forTesting(NativeDatabase.memory());
        final mockCrypto = CryptoService();
        final mockSecureStorage = FakeSecureStorageService();
        final mockPrefs = await SharedPreferences.getInstance();

        final mockContainer = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(mockPrefs),
            transportProvider.overrideWithValue(mockTransport),
            appDatabaseProvider.overrideWithValue(mockDb),
            secureStorageServiceProvider.overrideWithValue(mockSecureStorage),
            cryptoServiceProvider.overrideWithValue(mockCrypto),
          ],
        );
        addTearDown(() async {
          await mockDb.close();
          mockContainer.dispose();
        });

        await mockContainer.read(localIdentityStateProvider.notifier).ensureKeysLoaded();
        final notifier = mockContainer.read(messagingStateProvider.notifier);

        notifier.handshakeWatchdogDuration = const Duration(milliseconds: 100);

        mockTransport.triggerConnectionUpdate(const ConnectionUpdate(
          endpointId: 'QHZD',
          status: ConnectionStatus.connected,
          endpointName: 'RemotePeer:remote-peer-uuid',
        ));
        await Future.delayed(const Duration(milliseconds: 50));

        // Artificially populate a secure session and mapping
        final remotePeerId = 'remote-peer-uuid';
        final mockSession = SecuritySession(
          peerId: remotePeerId,
          endpointId: 'QHZD',
          sessionId: 'mock-session-id',
          sessionSalt: [],
          remoteIdentityPublicKey: 'mock-key',
          remoteFingerprint: 'mock-fp',
          sendKey: SecretKey([]),
          receiveKey: SecretKey([]),
        );
        notifier.securitySessions[remotePeerId] = mockSession;

        // Wait for the watchdog to fire (150ms)
        await Future.delayed(const Duration(milliseconds: 150));

        // It should skip disconnecting because currentSecSession is not null
        expect(mockTransport.disconnectCalled, isFalse);
      });
    });
  });
}

class DelayedCryptoService extends CryptoService {
  final Duration delay;
  DelayedCryptoService({required this.delay});

  @override
  Future<void> initializeDoubleRatchet({
    required SecuritySession session,
    required SimpleKeyPair handshakeLocalKeyPair,
    required List<int> handshakeRemotePublicKeyBytes,
    required bool isDeviceA,
  }) async {
    await Future.delayed(delay);
    await super.initializeDoubleRatchet(
      session: session,
      handshakeLocalKeyPair: handshakeLocalKeyPair,
      handshakeRemotePublicKeyBytes: handshakeRemotePublicKeyBytes,
      isDeviceA: isDeviceA,
    );
  }
}

class FailingCryptoService extends CryptoService {
  @override
  Future<void> initializeDoubleRatchet({
    required SecuritySession session,
    required SimpleKeyPair handshakeLocalKeyPair,
    required List<int> handshakeRemotePublicKeyBytes,
    required bool isDeviceA,
  }) async {
    throw Exception("Simulated Double Ratchet failure");
  }
}

