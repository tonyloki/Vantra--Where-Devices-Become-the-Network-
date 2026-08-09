import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:vantra/core/database/tables/messages.dart';
import 'package:vantra/core/database/tables/peers.dart';
import 'package:vantra/core/database/daos/message_dao.dart';
import 'package:vantra/core/database/daos/peer_dao.dart';
import 'package:vantra/core/models/message_status.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [Messages, Peers],
  daos: [MessageDao, PeerDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  AppDatabase.forTesting(super.connection);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (m) async {
        await m.createAll();
      },
      onUpgrade: (m, from, to) async {
        // Handled in future database upgrades
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
