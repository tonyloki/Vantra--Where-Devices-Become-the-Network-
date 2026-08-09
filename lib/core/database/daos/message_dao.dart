import 'package:drift/drift.dart';
import 'package:vantra/core/database/app_database.dart';
import 'package:vantra/core/database/tables/messages.dart';
import 'package:vantra/core/models/message_status.dart';

part 'message_dao.g.dart';

@DriftAccessor(tables: [Messages])
class MessageDao extends DatabaseAccessor<AppDatabase> with _$MessageDaoMixin {
  MessageDao(super.db);

  Future<int> insertMessage(Insertable<Message> message) {
    return into(messages).insert(message);
  }

  Future<bool> updateMessageStatus(String messageId, MessageStatus status) async {
    final query = update(messages)..where((t) => t.messageId.equals(messageId));
    final rowsAffected = await query.write(MessagesCompanion(
      status: Value(status),
    ));
    return rowsAffected > 0;
  }

  Future<Message?> getMessageById(String messageId) {
    return (select(messages)..where((t) => t.messageId.equals(messageId))).getSingleOrNull();
  }

  Stream<List<Message>> watchConversation(String localPeerId, String remotePeerId) {
    return (select(messages)
          ..where((t) =>
              (t.senderId.equals(localPeerId) & t.receiverId.equals(remotePeerId)) |
              (t.senderId.equals(remotePeerId) & t.receiverId.equals(localPeerId)))
          ..orderBy([(t) => OrderingTerm(expression: t.localId, mode: OrderingMode.asc)]))
        .watch();
  }

  Future<List<Message>> getConversation(String localPeerId, String remotePeerId) {
    return (select(messages)
          ..where((t) =>
              (t.senderId.equals(localPeerId) & t.receiverId.equals(remotePeerId)) |
              (t.senderId.equals(remotePeerId) & t.receiverId.equals(localPeerId)))
          ..orderBy([(t) => OrderingTerm(expression: t.localId, mode: OrderingMode.asc)]))
        .get();
  }

  Future<int> clearConversation(String localPeerId, String remotePeerId) {
    return (delete(messages)
          ..where((t) =>
              (t.senderId.equals(localPeerId) & t.receiverId.equals(remotePeerId)) |
              (t.senderId.equals(remotePeerId) & t.receiverId.equals(localPeerId))))
        .go();
  }
}
