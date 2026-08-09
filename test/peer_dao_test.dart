import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/models/peer_trust_state.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('PeerDao Tests', () {
    test('Insert, fetch, and update nickname on peer', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final peer = Peer(
        peerId: 'peer-1',
        displayName: 'Vantra-1234',
        lastKnownEndpointId: 'EP1',
        publicKey: 'pubkey-hex',
        fingerprint: 'AA:BB:CC',
        trustState: PeerTrustState.untrusted,
        protocolVersion: 1,
        lastSeen: now,
        createdAt: now,
        updatedAt: now,
      );

      await db.peerDao.insertOrUpdatePeer(peer);

      var fetched = await db.peerDao.getPeer('peer-1');
      expect(fetched, isNotNull);
      expect(fetched!.displayName, 'Vantra-1234');
      expect(fetched.nickname, isNull);

      // Set local nickname
      await db.peerDao.updateNickname('peer-1', 'Alice');
      fetched = await db.peerDao.getPeer('peer-1');
      expect(fetched!.nickname, 'Alice');
      expect(fetched.displayName, 'Vantra-1234'); // Remote name intact!
    });

    test('Trust state update and filtering streams (Trusted, Blocked)', () async {
      final now = DateTime.now().millisecondsSinceEpoch;

      final peerA = Peer(
        peerId: 'peer-a',
        displayName: 'Peer A',
        lastSeen: now,
        createdAt: now,
        updatedAt: now,
        trustState: PeerTrustState.untrusted,
      );

      final peerB = Peer(
        peerId: 'peer-b',
        displayName: 'Peer B',
        lastSeen: now + 10,
        createdAt: now,
        updatedAt: now,
        trustState: PeerTrustState.trusted,
      );

      final peerC = Peer(
        peerId: 'peer-c',
        displayName: 'Peer C',
        lastSeen: now + 20,
        createdAt: now,
        updatedAt: now,
        trustState: PeerTrustState.distrusted,
      );

      await db.peerDao.insertOrUpdatePeer(peerA);
      await db.peerDao.insertOrUpdatePeer(peerB);
      await db.peerDao.insertOrUpdatePeer(peerC);

      final allPeers = await db.peerDao.listPeers();
      expect(allPeers.length, 3);

      final trustedList = await db.peerDao.watchTrustedPeers().first;
      expect(trustedList.length, 1);
      expect(trustedList[0].peerId, 'peer-b');

      final blockedList = await db.peerDao.watchBlockedPeers().first;
      expect(blockedList.length, 1);
      expect(blockedList[0].peerId, 'peer-c');

      // Change Peer A to trusted
      await db.peerDao.updateTrustState('peer-a', PeerTrustState.trusted);
      final updatedTrusted = await db.peerDao.watchTrustedPeers().first;
      expect(updatedTrusted.length, 2);
    });

    test('Search peers matches both displayName and nickname', () async {
      final now = DateTime.now().millisecondsSinceEpoch;

      await db.peerDao.insertOrUpdatePeer(Peer(
        peerId: 'p1',
        displayName: 'Vantra-8899',
        nickname: 'Tony Stark',
        lastSeen: now,
        createdAt: now,
        updatedAt: now,
        trustState: PeerTrustState.untrusted,
      ));

      await db.peerDao.insertOrUpdatePeer(Peer(
        peerId: 'p2',
        displayName: 'Bruce Banner',
        lastSeen: now,
        createdAt: now,
        updatedAt: now,
        trustState: PeerTrustState.untrusted,
      ));

      final matchNickname = await db.peerDao.searchPeers('tony');
      expect(matchNickname.length, 1);
      expect(matchNickname[0].peerId, 'p1');

      final matchDisplayName = await db.peerDao.searchPeers('bruce');
      expect(matchDisplayName.length, 1);
      expect(matchDisplayName[0].peerId, 'p2');
    });
  });
}
