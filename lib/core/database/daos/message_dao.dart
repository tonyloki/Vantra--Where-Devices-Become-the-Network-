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

  Future<int> markConversationAsRead(String localPeerId, String remotePeerId) {
    return (update(messages)
          ..where((t) =>
              t.senderId.equals(remotePeerId) &
              t.receiverId.equals(localPeerId) &
              t.isRead.equals(false)))
        .write(const MessagesCompanion(
      isRead: Value(true),
    ));
  }

  Stream<int> watchUnreadCount(String localPeerId, String remotePeerId) {
    final countExp = messages.localId.count();
    final query = selectOnly(messages)
      ..addColumns([countExp])
      ..where(messages.senderId.equals(remotePeerId) &
          messages.receiverId.equals(localPeerId) &
          messages.isRead.equals(false));

    return query.map((row) => row.read(countExp) ?? 0).watchSingle();
  }

  Future<int> getUnreadCount(String localPeerId, String remotePeerId) async {
    final countExp = messages.localId.count();
    final query = selectOnly(messages)
      ..addColumns([countExp])
      ..where(messages.senderId.equals(remotePeerId) &
          messages.receiverId.equals(localPeerId) &
          messages.isRead.equals(false));

    final row = await query.getSingleOrNull();
    return row?.read(countExp) ?? 0;
  }

  Stream<List<Message>> watchAllMessages() {
    return (select(messages)..orderBy([(t) => OrderingTerm(expression: t.timestamp, mode: OrderingMode.desc)])).watch();
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

  Future<List<Message>> getPendingOrFailedMessages(String peerId) {
    return (select(messages)
          ..where((t) =>
              t.receiverId.equals(peerId) &
              (t.status.equals(MessageStatus.pending.name) | t.status.equals(MessageStatus.failed.name)))
          ..orderBy([(t) => OrderingTerm(expression: t.localId, mode: OrderingMode.asc)]))
        .get();
  }

  Future<List<Message>> getAllPendingOrFailedMessages() {
    return (select(messages)
          ..where((t) =>
              t.status.equals(MessageStatus.pending.name) | t.status.equals(MessageStatus.failed.name))
          ..orderBy([(t) => OrderingTerm(expression: t.localId, mode: OrderingMode.asc)]))
        .get();
  }

  Future<void> recoverSentMessages() async {
    await (update(messages)
          ..where((t) =>
              t.status.equals(MessageStatus.sent.name) |
              t.status.equals(MessageStatus.sending.name)))
        .write(const MessagesCompanion(
      status: Value(MessageStatus.pending),
    ));
  }

  Future<void> incrementRetryCount(String messageId, {int maxAttempts = 5}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await customUpdate(
      'UPDATE messages SET '
      '  retry_count = retry_count + 1, '
      '  last_attempt = ?, '
      '  status = CASE WHEN retry_count + 1 >= ? THEN ? ELSE status END '
      'WHERE message_id = ?',
      variables: [
        Variable.withInt(now),
        Variable.withInt(maxAttempts),
        Variable.withString(MessageStatus.failed.name),
        Variable.withString(messageId),
      ],
      updates: {messages},
    );
  }

  Future<Message?> getMessageByTransferId(String transferId) {
    return (select(messages)..where((t) => t.transferId.equals(transferId))).getSingleOrNull();
  }

  Future<bool> updateIncomingMediaDetails(String messageId, String mediaPath, MessageStatus status) async {
    final query = update(messages)..where((t) => t.messageId.equals(messageId));
    final rowsAffected = await query.write(MessagesCompanion(
      mediaPath: Value(mediaPath),
      status: Value(status),
    ));
    return rowsAffected > 0;
  }

  Future<int> deleteMessageById(String messageId) {
    return (delete(messages)..where((t) => t.messageId.equals(messageId))).go();
  }
}

