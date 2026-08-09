import 'package:drift/drift.dart';
import 'package:vantra/core/models/peer_trust_state.dart';

class PeerTrustStateConverter extends TypeConverter<PeerTrustState, String> {
  const PeerTrustStateConverter();

  @override
  PeerTrustState fromSql(String fromDb) {
    return PeerTrustState.values.firstWhere(
      (e) => e.name == fromDb,
      orElse: () => PeerTrustState.untrusted,
    );
  }

  @override
  String toSql(PeerTrustState value) {
    return value.name;
  }
}

class Peers extends Table {
  TextColumn get peerId => text()();
  TextColumn get displayName => text()();
  TextColumn get nickname => text().nullable()();
  TextColumn get lastKnownEndpointId => text().nullable()();
  TextColumn get publicKey => text().nullable()();
  TextColumn get fingerprint => text().nullable()();
  TextColumn get trustState => text()
      .map(const PeerTrustStateConverter())
      .withDefault(const Constant('untrusted'))();
  IntColumn get protocolVersion => integer().nullable()();
  IntColumn get lastSeen => integer()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {peerId};
}
