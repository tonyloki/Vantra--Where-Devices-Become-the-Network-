import 'package:drift/drift.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/database/tables/groups.dart';
import 'package:vantra/core/database/tables/group_members.dart';

part 'group_dao.g.dart';

@DriftAccessor(tables: [Groups, GroupMembers])
class GroupDao extends DatabaseAccessor<AppDatabase> with _$GroupDaoMixin {
  GroupDao(super.db);

  Future<int> insertOrUpdateGroup(Group group) {
    return into(groups).insertOnConflictUpdate(group);
  }

  Future<int> insertOrUpdateGroupMember(GroupMembersCompanion member) {
    return into(groupMembers).insertOnConflictUpdate(member);
  }

  Future<Group?> getGroup(String groupId) {
    return (select(groups)..where((t) => t.groupId.equals(groupId))).getSingleOrNull();
  }

  Future<List<GroupMember>> getGroupMembers(String groupId) {
    return (select(groupMembers)..where((t) => t.groupId.equals(groupId))).get();
  }

  Stream<List<Group>> watchGroups() {
    return (select(groups)..orderBy([(t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc)])).watch();
  }

  Stream<List<GroupMember>> watchGroupMembers(String groupId) {
    return (select(groupMembers)..where((t) => t.groupId.equals(groupId))).watch();
  }

  Stream<Group?> watchGroup(String groupId) {
    return (select(groups)..where((t) => t.groupId.equals(groupId))).watchSingleOrNull();
  }

  Future<void> deleteGroup(String groupId) async {
    await (delete(groups)..where((t) => t.groupId.equals(groupId))).go();
    await (delete(groupMembers)..where((t) => t.groupId.equals(groupId))).go();
  }
}
