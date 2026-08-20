import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:drift/native.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/identity/local_identity.dart';
import 'package:vantra/core/identity/local_identity_provider.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'package:vantra/core/security/secure_storage_service.dart';
import 'package:vantra/core/security/crypto_service.dart';
import 'package:vantra/core/calls/call_provider.dart';
import 'package:vantra/core/calls/call_session.dart';
import 'test_fakes.dart';

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

  group('Audio Call Signaling & State Machine Tests', () {
    late FakeTransport fakeTransport;
    late ProviderContainer container;
    late AppDatabase testDb;
    late String remotePeerId;
    late LocalIdentity identityA;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      fakeTransport = FakeTransport();
      testDb = AppDatabase.forTesting(NativeDatabase.memory());
      remotePeerId = const Uuid().v4();

      final keyPairA = await cryptoService.generateIdentityKeyPair();
      final pubKeyA = await keyPairA.extractPublicKey();
      identityA = LocalIdentity(
        peerId: 'peer-a-uuid',
        displayName: 'Device A',
        identityPublicKey: pubKeyA.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        fingerprint: await cryptoService.computeFingerprint(pubKeyA.bytes),
        keyPair: keyPairA,
      );

      container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          transportProvider.overrideWithValue(fakeTransport),
          appDatabaseProvider.overrideWithValue(testDb),
          secureStorageServiceProvider.overrideWithValue(FakeSecureStorageService()),
          localIdentityStateProvider.overrideWith(() => FakeIdentityNotifier(identityA)),
        ],
      );

      // Initialize messaging notifier
      container.read(messagingStateProvider);
    });

    tearDown(() async {
      await testDb.close();
      container.dispose();
    });

    test('Initial call status is idle (null session)', () {
      final callSession = container.read(callStateProvider);
      expect(callSession, isNull);
    });

    test('initiateCall updates state to outgoing and sets call session details', () async {
      final notifier = container.read(callStateProvider.notifier);
      await notifier.initiateCall(remotePeerId);

      final callSession = container.read(callStateProvider);
      expect(callSession, isNotNull);
      expect(callSession!.peerId, remotePeerId);
      expect(callSession.status, CallStatus.outgoing);
      expect(callSession.isMuted, isFalse);
      expect(callSession.isSpeaker, isFalse);
      expect(callSession.callId.isNotEmpty, isTrue);
    });

    test('handleIncomingOffer transitions state to incoming', () {
      final notifier = container.read(callStateProvider.notifier);
      final callId = const Uuid().v4();

      notifier.handleIncomingOffer(remotePeerId, callId);

      final callSession = container.read(callStateProvider);
      expect(callSession, isNotNull);
      expect(callSession!.callId, callId);
      expect(callSession.peerId, remotePeerId);
      expect(callSession.status, CallStatus.incoming);
    });

    test('answerCall transitions incoming to active', () {
      final notifier = container.read(callStateProvider.notifier);
      final callId = const Uuid().v4();

      notifier.handleIncomingOffer(remotePeerId, callId);
      notifier.answerCall();

      final callSession = container.read(callStateProvider);
      expect(callSession, isNotNull);
      expect(callSession!.status, CallStatus.active);
      expect(callSession.startedAt, isNotNull);
    });

    test('declineCall resets call state to null', () {
      final notifier = container.read(callStateProvider.notifier);
      final callId = const Uuid().v4();

      notifier.handleIncomingOffer(remotePeerId, callId);
      notifier.declineCall();

      final callSession = container.read(callStateProvider);
      expect(callSession, isNull);
    });

    test('endCall transitions state to ended and cleans up call session', () async {
      final notifier = container.read(callStateProvider.notifier);
      final callId = const Uuid().v4();

      notifier.handleIncomingOffer(remotePeerId, callId);
      notifier.answerCall();
      notifier.endCall();

      final callSession = container.read(callStateProvider);
      expect(callSession!.status, CallStatus.ended);

      // Verify it auto-clears to null after a delay
      await Future.delayed(const Duration(milliseconds: 1100));
      final clearedSession = container.read(callStateProvider);
      expect(clearedSession, isNull);
    });

    test('toggleMute and toggleSpeaker toggle session states', () {
      final notifier = container.read(callStateProvider.notifier);
      final callId = const Uuid().v4();

      notifier.handleIncomingOffer(remotePeerId, callId);
      notifier.answerCall();

      notifier.toggleMute();
      expect(container.read(callStateProvider)!.isMuted, isTrue);

      notifier.toggleSpeaker();
      expect(container.read(callStateProvider)!.isSpeaker, isTrue);
    });
  });
}
