import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:vantra/core/database/tables/messages.dart';
import 'package:vantra/core/database/tables/peers.dart';
import 'package:vantra/core/database/daos/message_dao.dart';
import 'package:vantra/core/database/daos/peer_dao.dart';
import 'package:vantra/core/models/message_status.dart';
import 'package:vantra/core/models/peer_trust_state.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [Messages, Peers],
  daos: [MessageDao, PeerDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  AppDatabase.forTesting(super.connection);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (m) async {
        await m.createAll();
      },
      onUpgrade: (m, from, to) async {
        if (from < 2) {
          await m.addColumn(peers, peers.publicKey);
          await m.addColumn(peers, peers.fingerprint);
          await m.addColumn(peers, peers.trustState);
          await m.addColumn(peers, peers.protocolVersion);
        }
      },
      beforeOpen: (details) async {
        // Enforce foreign key constraints if needed in the future
      },
    );
  }

  static QueryExecutor _openConnection() {
    return driftDatabase(name: 'vantra_database');
  }
}
