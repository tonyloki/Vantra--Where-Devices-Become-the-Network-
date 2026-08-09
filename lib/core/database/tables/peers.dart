import 'package:drift/drift.dart';

class Peers extends Table {
  TextColumn get peerId => text()();
  TextColumn get displayName => text()();
  TextColumn get lastKnownEndpointId => text().nullable()();
  IntColumn get lastSeen => integer()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {peerId};
}
