import 'package:drift/drift.dart';

class GroupMembers extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get groupId => text()();
  TextColumn get peerId => text()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {groupId, peerId}
  ];
}
