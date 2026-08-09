import 'package:drift/drift.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/database/tables/peers.dart';

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
    return select(peers).watch();
  }

  Future<List<Peer>> listPeers() {
    return select(peers).get();
  }
}
