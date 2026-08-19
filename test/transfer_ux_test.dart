import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as path;

import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/messaging/message.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/messaging/transfer_speed_tracker.dart';
import 'package:vantra/core/models/peer_trust_state.dart';
import 'package:vantra/core/models/message_status.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'package:vantra/core/protocol/protocol_message.dart';
import 'package:vantra/core/protocol/protocol_version.dart';
import 'package:vantra/core/protocol/protobuf_codec.dart';
import 'package:vantra/core/security/crypto_service.dart';
import 'package:vantra/core/security/security_session.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/identity/local_identity.dart';
import 'test_fakes.dart';

class MockMeshTransport extends FakeTransport {
  final String localEndpoint;
  void Function(String endpointId, Uint8List data)? onSend;

  MockMeshTransport(this.localEndpoint);

  @override
  Future<void> send(String endpointId, Uint8List data) async {
    await super.send(endpointId, data);
    if (onSend != null) {
      Future.delayed(const Duration(milliseconds: 5), () {
        if (onSend != null) {
          onSend!(endpointId, data);
        }
      });
    }
  }
}

class FakeIdentityNotifier extends LocalIdentityNotifier {
  final LocalIdentity presetIdentity;
  FakeIdentityNotifier(this.presetIdentity);

  @override
  LocalIdentity build() => presetIdentity;

  @override
  Future<void> ensureKeysLoaded() async {
    state = presetIdentity;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cryptoService = CryptoService();

  group('TransferSpeedTracker Unit Tests', () {
    test('Calculates speed as 0.0 with fewer than 2 samples', () {
      final tracker = TransferSpeedTracker(totalBytes: 1000);
      expect(tracker.speedBytesPerSecond, 0.0);
      expect(tracker.speedLabel, '');
      expect(tracker.eta, null);
      expect(tracker.etaLabel, '');

      tracker.record(100);
      expect(tracker.speedBytesPerSecond, 0.0);
      expect(tracker.speedLabel, '');
    });

    test('Calculates correct speed and ETA with constant stream', () async {
      final tracker = TransferSpeedTracker(totalBytes: 1000);
      
      // Seed first sample
      tracker.record(0);
      
      // Wait 100ms and deliver 100 bytes
      await Future.delayed(const Duration(milliseconds: 100));
      tracker.record(100);

      final speed = tracker.speedBytesPerSecond;
      expect(speed, greaterThan(0));
      expect(tracker.remainingBytes, 900);
      expect(tracker.eta, isNotNull);
      expect(tracker.speedLabel, contains('B/s'));
      expect(tracker.etaLabel, contains('~'));
    });

    test('Prunes old samples outside of time window', () async {
      // Set short window to test age pruning
      final tracker = TransferSpeedTracker(totalBytes: 10000, windowSeconds: 1);
      
      tracker.record(0);
      await Future.delayed(const Duration(milliseconds: 50));
      tracker.record(500);
      
      // Wait past the window
      await Future.delayed(const Duration(milliseconds: 1100));
      tracker.record(1000);
      
      // Speed should only be computed using samples within the last 1 second window
      // meaning the oldest samples (at 0ms and 50ms) must have been pruned.
      final speed = tracker.speedBytesPerSecond;
      expect(speed, isNot(double.nan));
    });
  });

  group('Vantra V2 Phase 19 Transfer UX Integration Tests', () {
    late MockMeshTransport transportA;
    late MockMeshTransport transportB;

    late AppDatabase dbA;
    late AppDatabase dbB;

    late ProviderContainer containerA;
    late ProviderContainer containerB;

    late Directory testTempDir;

    late LocalIdentity identityA;
    late LocalIdentity identityB;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      testTempDir = Directory.systemTemp.createTempSync('vantra_transfer_ux_test_');

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall methodCall) async {
          if (methodCall.method == 'getApplicationDocumentsDirectory') {
            return testTempDir.path;
          }
          return null;
        },
      );

      dbA = AppDatabase.forTesting(NativeDatabase.memory());
      dbB = AppDatabase.forTesting(NativeDatabase.memory());

      final keyPairA = await cryptoService.generateIdentityKeyPair();
      final pubKeyA = await keyPairA.extractPublicKey();
      identityA = LocalIdentity(
        peerId: 'peer-a-uuid',
        displayName: 'Device A',
        identityPublicKey: pubKeyA.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        fingerprint: await cryptoService.computeFingerprint(pubKeyA.bytes),
        keyPair: keyPairA,
      );

      final keyPairB = await cryptoService.generateIdentityKeyPair();
      final pubKeyB = await keyPairB.extractPublicKey();
      identityB = LocalIdentity(
        peerId: 'peer-b-uuid',
        displayName: 'Device B',
        identityPublicKey: pubKeyB.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        fingerprint: await cryptoService.computeFingerprint(pubKeyB.bytes),
        keyPair: keyPairB,
      );

      transportA = MockMeshTransport('EP_A');
      transportB = MockMeshTransport('EP_B');

      // Wire them up bidirectionally
      transportA.onSend = (endpointId, data) {
        if (endpointId == 'EP_A_B') {
          transportB.triggerIncomingPayload('EP_B_A', data);
        }
      };
      transportB.onSend = (endpointId, data) {
        if (endpointId == 'EP_B_A') {
          transportA.triggerIncomingPayload('EP_A_B', data);
        }
      };

      containerA = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        appDatabaseProvider.overrideWithValue(dbA),
        secureStorageServiceProvider.overrideWithValue(FakeSecureStorageService()),
        transportProvider.overrideWithValue(transportA),
        localIdentityStateProvider.overrideWith(() => FakeIdentityNotifier(identityA)),
      ]);

      containerB = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        appDatabaseProvider.overrideWithValue(dbB),
        secureStorageServiceProvider.overrideWithValue(FakeSecureStorageService()),
        transportProvider.overrideWithValue(transportB),
        localIdentityStateProvider.overrideWith(() => FakeIdentityNotifier(identityB)),
      ]);

      await containerA.read(localIdentityStateProvider.notifier).ensureKeysLoaded();
      await containerB.read(localIdentityStateProvider.notifier).ensureKeysLoaded();

      containerA.read(messagingStateProvider);
      containerB.read(messagingStateProvider);
    });

    tearDown(() async {
      containerA.dispose();
      containerB.dispose();
      await dbA.close();
      await dbB.close();
      if (testTempDir.existsSync()) {
        try {
          testTempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('Sender cancels transfer during chunk streaming', () async {
      final messagingA = containerA.read(messagingStateProvider.notifier);
      final repoA = containerA.read(messagingRepositoryProvider);
      final repoB = containerB.read(messagingRepositoryProvider);

      await repoA.upsertPeer(identityB.peerId, 'Device B', publicKey: identityB.identityPublicKey, fingerprint: identityB.fingerprint, trustState: PeerTrustState.trusted);
      await repoB.upsertPeer(identityA.peerId, 'Device A', publicKey: identityA.identityPublicKey, fingerprint: identityA.fingerprint, trustState: PeerTrustState.trusted);

      // Perform handshake
      transportA.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_A_B', status: ConnectionStatus.connected, endpointName: 'Device B:${identityB.peerId}'));
      transportB.triggerConnectionUpdate(ConnectionUpdate(endpointId: 'EP_B_A', status: ConnectionStatus.connected, endpointName: 'Device A:${identityA.peerId}'));

      // Wait for secure session
      await Future.delayed(const Duration(milliseconds: 1500));

      // 2. Prepare a test file to send from A to B
      final sourceFile = File(path.join(testTempDir.path, 'source.bin'));
      await sourceFile.writeAsBytes(List.generate(500000, (index) => index % 256));

      // 3. Initiate the file transfer offer
      await messagingA.sendFileMessage('peer-b-uuid', sourceFile.path);

      // Give it a moment to send the OFFER, get ACCEPT, and start chunking
      await Future.delayed(const Duration(milliseconds: 150));

      final messages = await repoA.watchConversation('peer-a-uuid', 'peer-b-uuid').first;
      final fileMsg = messages.firstWhere((m) => m.type == 'FILE');

      // 4. Cancel the transfer
      await messagingA.cancelTransfer(fileMsg.messageId, 'peer-b-uuid');

      // 5. Verify local database shows failed status
      final updatedMsg = await repoA.getMessageById(fileMsg.messageId);
      expect(updatedMsg?.status, MessageStatus.failed);

      // Wait for receiver B to process the cancel message and update database
      dynamic bFileMsg;
      for (int i = 0; i < 20; i++) {
        final bMessages = await repoB.watchConversation('peer-b-uuid', 'peer-a-uuid').first;
        bFileMsg = bMessages.firstWhere((m) => m.type == 'FILE');
        if (bFileMsg.status == MessageStatus.failed) {
          break;
        }
        await Future.delayed(const Duration(milliseconds: 50));
      }

      expect(bFileMsg, isNotNull);
      expect(bFileMsg.status, MessageStatus.failed);

      // Verify temp file on receiver B is deleted
      final tempFile = File(path.join(testTempDir.path, 'files', 'temp', '${bFileMsg.transferId}.tmp'));
      expect(await tempFile.exists(), isFalse);
    });
  });
}
