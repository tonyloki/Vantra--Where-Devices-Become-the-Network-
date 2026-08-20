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
import 'package:vantra/core/messaging/messaging_repository.dart';
import 'package:vantra/core/messaging/message.dart';
import 'package:vantra/core/networking/transport.dart';
import 'package:vantra/core/networking/transport_provider.dart';
import 'package:vantra/core/security/secure_storage_service.dart';
import 'package:vantra/core/security/crypto_service.dart';
import 'package:vantra/core/models/message_status.dart';
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

  group('Group Messaging & Invite Tests', () {
    late FakeTransport fakeTransport;
    late ProviderContainer container;
    late AppDatabase testDb;
    late String peerB;
    late String peerC;
    late LocalIdentity identityA;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      fakeTransport = FakeTransport();
      testDb = AppDatabase.forTesting(NativeDatabase.memory());
      peerB = const Uuid().v4();
      peerC = const Uuid().v4();

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

    test('createAndInviteGroup inserts group and membership records locally', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repository = container.read(messagingRepositoryProvider);

      final groupName = 'Secret Agents';
      final memberIds = [peerB, peerC];

      await notifier.createAndInviteGroup(groupName, memberIds);

      // Verify group was created
      final groups = await testDb.groupDao.watchGroups().first;
      expect(groups.length, 1);
      expect(groups.first.name, groupName);

      final groupId = groups.first.groupId;

      // Verify memberships (including initiator)
      final members = await repository.getGroupMembers(groupId);
      final memberPeerIds = members.map((m) => m.peerId).toList();
      expect(memberPeerIds.contains(identityA.peerId), isTrue);
      expect(memberPeerIds.contains(peerB), isTrue);
      expect(memberPeerIds.contains(peerC), isTrue);
    });

    test('sendGroupMessage persists message with groupId populated', () async {
      final notifier = container.read(messagingStateProvider.notifier);
      final repository = container.read(messagingRepositoryProvider);

      final groupName = 'Test Group';
      await notifier.createAndInviteGroup(groupName, [peerB]);

      final groups = await testDb.groupDao.watchGroups().first;
      final groupId = groups.first.groupId;

      await notifier.sendGroupMessage(groupId, 'Hello everyone!');

      // Retrieve messages
      final messages = await repository.getGroupMessages(groupId);
      expect(messages.length, 1);
      expect(messages.first.text, 'Hello everyone!');
      expect(messages.first.groupId, groupId);
      expect(messages.first.senderId, identityA.peerId);
    });
  });
}
