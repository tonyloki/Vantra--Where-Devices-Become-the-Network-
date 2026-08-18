import 'package:drift/drift.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/database/tables/peers.dart';
import 'package:vantra/core/models/peer_trust_state.dart';

part 'peer_dao.g.dart';

@DriftAccessor(tables: [Peers])
class PeerDao extends DatabaseAccessor<AppDatabase> with _$PeerDaoMixin {
  PeerDao(super.db);

  Future<int> insertOrUpdatePeer(Peer peer) {
    return into(peers).insertOnConflictUpdate(peer);
  }

  Future<Peer?> getPeer(String peerId) {
    return (select(peers)..where((t) => t.peerId.equals(peerId))).getSingleOrNull();
  }

  Stream<List<Peer>> watchPeers() {
    return (select(peers)..orderBy([(t) => OrderingTerm(expression: t.lastSeen, mode: OrderingMode.desc)])).watch();
  }

  Stream<List<Peer>> watchAllPeers() {
    return watchPeers();
  }

  Stream<List<Peer>> watchTrustedPeers() {
    return (select(peers)
          ..where((t) => t.trustState.equalsValue(PeerTrustState.trusted))
          ..orderBy([(t) => OrderingTerm(expression: t.lastSeen, mode: OrderingMode.desc)]))
        .watch();
  }

  Stream<List<Peer>> watchBlockedPeers() {
    return (select(peers)
          ..where((t) => t.trustState.equalsValue(PeerTrustState.distrusted))
          ..orderBy([(t) => OrderingTerm(expression: t.lastSeen, mode: OrderingMode.desc)]))
        .watch();
  }

  Stream<Peer?> watchPeer(String peerId) {
    return (select(peers)..where((t) => t.peerId.equals(peerId))).watchSingleOrNull();
  }

  Future<List<Peer>> searchPeers(String query) {
    final pattern = '%$query%';
    return (select(peers)
          ..where((t) => t.displayName.like(pattern) | t.nickname.like(pattern))
          ..orderBy([(t) => OrderingTerm(expression: t.lastSeen, mode: OrderingMode.desc)]))
        .get();
  }

  Future<bool> updateNickname(String peerId, String? nickname) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rowsAffected = await (update(peers)..where((t) => t.peerId.equals(peerId))).write(
      PeersCompanion(
        nickname: Value(nickname),
        updatedAt: Value(now),
      ),
    );
    return rowsAffected > 0;
  }

  Future<bool> updateTrustState(String peerId, PeerTrustState trustState) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rowsAffected = await (update(peers)..where((t) => t.peerId.equals(peerId))).write(
      PeersCompanion(
        trustState: Value(trustState),
        updatedAt: Value(now),
      ),
    );
    return rowsAffected > 0;
  }

  Future<bool> updateLastSeen(String peerId, int lastSeen) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rowsAffected = await (update(peers)..where((t) => t.peerId.equals(peerId))).write(
      PeersCompanion(
        lastSeen: Value(lastSeen),
        updatedAt: Value(now),
      ),
    );
    return rowsAffected > 0;
  }

  Future<List<Peer>> listPeers() {
    return (select(peers)..orderBy([(t) => OrderingTerm(expression: t.lastSeen, mode: OrderingMode.desc)])).get();
  }

  Future<int> deletePeerById(String peerId) {
    return (delete(peers)..where((t) => t.peerId.equals(peerId))).go();
  }
}

