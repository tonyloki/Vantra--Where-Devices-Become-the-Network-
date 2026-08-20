import 'package:drift/drift.dart';

class Groups extends Table {
  TextColumn get groupId => text()();
  TextColumn get name => text()();
  TextColumn get creatorId => text()();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {groupId};
}
