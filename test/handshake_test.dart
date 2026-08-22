import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
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

    group('Stale Handshake Continuation Race Prevention Tests', () {
      test('TEST: stale handshake continuation after disconnect', () async {
        final pausableCrypto = PausableCryptoService();
        pausableCrypto.deriveSessionKeysCompleter = Completer<void>();

        final testContainer = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
            transportProvider.overrideWithValue(fakeTransport),
            appDatabaseProvider.overrideWithValue(testDb),
            secureStorageServiceProvider.overrideWithValue(FakeSecureStorageService()),
            cryptoServiceProvider.overrideWithValue(pausableCrypto),
          ],
        );
        addTearDown(testContainer.dispose);

        await testContainer.read(localIdentityStateProvider.notifier).ensureKeysLoaded();
        final notifier = testContainer.read(messagingStateProvider.notifier);

        final remoteIdentityKeyPair = await cryptoService.generateIdentityKeyPair();
        final remoteEphemeralKeyPair = await cryptoService.generateEphemeralKeyPair();
        final remoteIdPub = await remoteIdentityKeyPair.extractPublicKey();
        final remoteEphPub = await remoteEphemeralKeyPair.extractPublicKey();
        final remotePeerId = const Uuid().v4();

        // 1. Start handshake for endpoint E (QHZD)
        fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
          endpointId: 'QHZD',
          status: ConnectionStatus.connected,
          endpointName: 'RemoteStaleTestPeer:$remotePeerId',
        ));
        await Future.delayed(const Duration(milliseconds: 50));

        final sigBytes = await cryptoService.signHandshake(
          identityKeyPair: remoteIdentityKeyPair,
          protocolVersion: kCurrentProtocolVersion,
          peerId: remotePeerId,
          displayName: 'RemoteStaleTestPeer',
          identityPublicKeyBytes: remoteIdPub.bytes,
          ephemeralPublicKeyBytes: remoteEphPub.bytes,
        );

        final handshakeMessage = DomainHandshakePayload(
          protocolVersion: kCurrentProtocolVersion,
          peerId: remotePeerId,
          displayName: 'RemoteStaleTestPeer',
          identityPublicKey: Uint8List.fromList(remoteIdPub.bytes),
          ephemeralPublicKey: Uint8List.fromList(remoteEphPub.bytes),
          signature: Uint8List.fromList(sigBytes),
          minSupportedVersion: kMinSupportedProtocolVersion,
          maxSupportedVersion: kCurrentProtocolVersion,
        );

        // Deliver handshake payload
        fakeTransport.triggerIncomingPayload('QHZD', codec.encodeWireEnvelope(handshakeMessage));

        // 2. Pause deriveSessionKeys() - wait until paused
        await Future.delayed(const Duration(milliseconds: 50));
        expect(pausableCrypto.deriveSessionKeysCompleter!.isCompleted, isFalse);

        // 3. Emit ConnectionStatus.disconnected for E (QHZD)
        fakeTransport.triggerConnectionUpdate(ConnectionUpdate(
          endpointId: 'QHZD',
          status: ConnectionStatus.disconnected,
          endpointName: 'RemoteStaleTestPeer:$remotePeerId',
        ));
        await Future.delayed(const Duration(milliseconds: 50));

        // 4. Verify:
        // - endpoint removed from alive endpoints
        // - security session removed
        // - PeerSession becomes disconnected
        expect(notifier.aliveEndpoints.contains('QHZD'), isFalse);
        expect(notifier.securitySessions[remotePeerId], isNull);
        final stateAfterDisconnect = testContainer.read(messagingStateProvider);
        expect(stateAfterDisconnect.sessions[remotePeerId]?.status, SessionStatus.disconnected);
        expect(stateAfterDisconnect.sessions[remotePeerId]?.isSecure, isFalse);

        // Clear sent payloads tracking to observe any stale outbound packets
        fakeTransport.sentPayloads.clear();
        fakeTransport.disconnectCalled = false;

        // 5. Resume deriveSessionKeys()
        pausableCrypto.deriveSessionKeysCompleter!.complete();
        await Future.delayed(const Duration(milliseconds: 100));

        // 6. Verify handshake continuation aborts
        // 7. Verify:
        // - no security session is recreated
        // - state is NOT changed back to handshaking/secure
        // - no capabilities exchange is sent
        // - no transport disconnect is triggered by the stale continuation
        expect(notifier.securitySessions[remotePeerId], isNull);
        final stateAfterResume = testContainer.read(messagingStateProvider);
        expect(stateAfterResume.sessions[remotePeerId]?.status, SessionStatus.disconnected);
        expect(stateAfterResume.sessions[remotePeerId]?.isSecure, isFalse);
        expect(fakeTransport.sentPayloads.isEmpty, isTrue);
        expect(fakeTransport.disconnectCalled, isFalse);
      });

      test('TEST: old handshake cannot overwrite newer connection', () async {
        final pausableCrypto = PausableCryptoService();
        pausableCrypto.deriveSessionKeysCompleter = Completer<void>();

        final testContainer = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
            transportProvider.overrideWithValue(fakeTransport),
            appDatabaseProvider.overrideWithValue(testDb),
            secureStorageServiceProvider.overrideWithValue(FakeSecureStorageService()),
            cryptoServiceProvider.overrideWithValue(pausableCrypto),
          ],
        );
        addTearDown(testContainer.dispose);

        await testContainer.read(localIdentityStateProvider.notifier).ensureKeysLoaded();
        final notifier = testContainer.read(messagingStateProvider.notifier);

        // 1. Start handshake generation 1 on endpoint E (QHZD) for peer 1
        fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
          endpointId: 'QHZD',
          status: ConnectionStatus.connected,
          endpointName: 'QHZD',
        ));
        await Future.delayed(const Duration(milliseconds: 50));

        final peer1IdentityKeyPair = await cryptoService.generateIdentityKeyPair();
        final peer1EphemeralKeyPair = await cryptoService.generateEphemeralKeyPair();
        final peer1IdPub = await peer1IdentityKeyPair.extractPublicKey();
        final peer1EphPub = await peer1EphemeralKeyPair.extractPublicKey();
        final peer1Id = const Uuid().v4();

        final peer1Sig = await cryptoService.signHandshake(
          identityKeyPair: peer1IdentityKeyPair,
          protocolVersion: kCurrentProtocolVersion,
          peerId: peer1Id,
          displayName: 'Gen1Peer',
          identityPublicKeyBytes: peer1IdPub.bytes,
          ephemeralPublicKeyBytes: peer1EphPub.bytes,
        );

        final peer1Payload = DomainHandshakePayload(
          protocolVersion: kCurrentProtocolVersion,
          peerId: peer1Id,
          displayName: 'Gen1Peer',
          identityPublicKey: Uint8List.fromList(peer1IdPub.bytes),
          ephemeralPublicKey: Uint8List.fromList(peer1EphPub.bytes),
          signature: Uint8List.fromList(peer1Sig),
          minSupportedVersion: kMinSupportedProtocolVersion,
          maxSupportedVersion: kCurrentProtocolVersion,
        );

        fakeTransport.triggerIncomingPayload('QHZD', codec.encodeWireEnvelope(peer1Payload));
        await Future.delayed(const Duration(milliseconds: 50));

        final gen1Completer = pausableCrypto.deriveSessionKeysCompleter!;
        expect(gen1Completer.isCompleted, isFalse);
        final initialGen = notifier.handshakeGenerations['QHZD'];
        expect(initialGen, isNotNull);

        // 2. Disconnect E
        fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
          endpointId: 'QHZD',
          status: ConnectionStatus.disconnected,
          endpointName: 'QHZD',
        ));
        await Future.delayed(const Duration(milliseconds: 50));
        expect(notifier.handshakeGenerations['QHZD'], isNull);

        // 3. Start generation 2 on endpoint E for peer 2
        fakeTransport.triggerConnectionUpdate(const ConnectionUpdate(
          endpointId: 'QHZD',
          status: ConnectionStatus.connected,
          endpointName: 'QHZD',
        ));
        await Future.delayed(const Duration(milliseconds: 50));

        // Gen 2 will complete immediately
        pausableCrypto.deriveSessionKeysCompleter = null;

        final peer2IdentityKeyPair = await cryptoService.generateIdentityKeyPair();
        final peer2EphemeralKeyPair = await cryptoService.generateEphemeralKeyPair();
        final peer2IdPub = await peer2IdentityKeyPair.extractPublicKey();
        final peer2EphPub = await peer2EphemeralKeyPair.extractPublicKey();
        final peer2Id = const Uuid().v4();

        final peer2Sig = await cryptoService.signHandshake(
          identityKeyPair: peer2IdentityKeyPair,
          protocolVersion: kCurrentProtocolVersion,
          peerId: peer2Id,
          displayName: 'Gen2Peer',
          identityPublicKeyBytes: peer2IdPub.bytes,
          ephemeralPublicKeyBytes: peer2EphPub.bytes,
        );

        final peer2Payload = DomainHandshakePayload(
          protocolVersion: kCurrentProtocolVersion,
          peerId: peer2Id,
          displayName: 'Gen2Peer',
          identityPublicKey: Uint8List.fromList(peer2IdPub.bytes),
          ephemeralPublicKey: Uint8List.fromList(peer2EphPub.bytes),
          signature: Uint8List.fromList(peer2Sig),
          minSupportedVersion: kMinSupportedProtocolVersion,
          maxSupportedVersion: kCurrentProtocolVersion,
        );

        fakeTransport.triggerIncomingPayload('QHZD', codec.encodeWireEnvelope(peer2Payload));
        await Future.delayed(const Duration(milliseconds: 100));

        final gen2 = notifier.handshakeGenerations['QHZD'];
        expect(gen2, isNotNull);
        expect(gen2, isNot(equals(initialGen)));
        expect(notifier.securitySessions[peer2Id], isNotNull);
        expect(testContainer.read(messagingStateProvider).sessions[peer2Id]?.isSecure, isTrue);

        // 4. Resume generation 1
        gen1Completer.complete();
        await Future.delayed(const Duration(milliseconds: 100));

        // 5. Verify generation 1 cannot modify:
        // - securitySessions
        // - state.sessions
        // - endpoint mappings
        // - capabilities exchange
        expect(notifier.securitySessions[peer1Id], isNull);
        expect(notifier.securitySessions[peer2Id]?.peerId, peer2Id);
        final finalState = testContainer.read(messagingStateProvider);
        expect(finalState.sessions[peer1Id]?.isSecure ?? false, isFalse);
        expect(finalState.sessions[peer2Id]?.isSecure, isTrue);
        expect(finalState.endpointToPeerId['QHZD'], peer2Id);
      });

      test('TEST: initializeDoubleRatchet succeeds without empty key platform exceptions', () async {
        final localKeyPair = await cryptoService.generateEphemeralKeyPair();
        final remoteKeyPair = await cryptoService.generateEphemeralKeyPair();
        final remotePub = await remoteKeyPair.extractPublicKey();

        final session = SecuritySession(
          peerId: 'test-peer-id',
          endpointId: 'QHZD',
          sessionId: 'test-session-id',
          sessionSalt: List<int>.filled(64, 1),
          remoteIdentityPublicKey: 'test-pub-key',
          remoteFingerprint: 'test-fingerprint',
          sendKey: SecretKey([]),
          receiveKey: SecretKey([]),
        );

        // After the fix, this must complete successfully without throwing
        await cryptoService.initializeDoubleRatchet(
          session: session,
          handshakeLocalKeyPair: localKeyPair,
          handshakeRemotePublicKeyBytes: remotePub.bytes,
          isDeviceA: true,
        );

        expect(session.rootKey, isNotNull);
        expect(session.sendingChainKey, isNotNull);
      });
    });
  });
}

class PausableCryptoService extends CryptoService {
  Completer<void>? deriveSessionKeysCompleter;

  @override
  Future<DerivedSessionKeys> deriveSessionKeys({
    required SimpleKeyPair localEphemeralKeyPair,
    required List<int> remoteEphemeralPublicKeyBytes,
  }) async {
    if (deriveSessionKeysCompleter != null) {
      await deriveSessionKeysCompleter!.future;
    }
    return super.deriveSessionKeys(
      localEphemeralKeyPair: localEphemeralKeyPair,
      remoteEphemeralPublicKeyBytes: remoteEphemeralPublicKeyBytes,
    );
  }
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

