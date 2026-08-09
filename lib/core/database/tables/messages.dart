import 'package:drift/drift.dart';
import 'package:vantra/core/models/message_status.dart';

class MessageStatusConverter extends TypeConverter<MessageStatus, String> {
  const MessageStatusConverter();

  @override
  MessageStatus fromSql(String fromDb) {
    return MessageStatus.values.firstWhere(
      (e) => e.name == fromDb,
      orElse: () => MessageStatus.pending,
    );
  }

  @override
  String toSql(MessageStatus value) {
    return value.name;
  }
}

class Messages extends Table {
  IntColumn get localId => integer().autoIncrement()();
  TextColumn get messageId => text().unique()();
  TextColumn get senderId => text()();
  TextColumn get receiverId => text()();
  TextColumn get messageText => text().named('text')();
  IntColumn get timestamp => integer()();
  TextColumn get type => text()();
  TextColumn get status => text().map(const MessageStatusConverter())();
  BoolColumn get isRead => boolean().withDefault(const Constant(false))();
  IntColumn get createdAt => integer()();
}
