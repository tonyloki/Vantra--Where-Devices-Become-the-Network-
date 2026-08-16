import 'package:drift/drift.dart';
import 'package:vantra/core/models/message_status.dart';

class MessageStatusConverter extends TypeConverter<MessageStatus, String> {
  const MessageStatusConverter();

  @override
  MessageStatus fromSql(String fromDb) {
    return MessageStatus.values.firstWhere(
      (e) => e.name == fromDb,
      orElse: () => MessageStatus.received,
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
  IntColumn get retryCount => integer().withDefault(const Constant(0))();
  IntColumn get lastAttempt => integer().nullable()();
  TextColumn get mediaPath => text().nullable()();
  TextColumn get mimeType => text().nullable()();
  TextColumn get fileName => text().nullable()();
  IntColumn get fileSize => integer().nullable()();
  IntColumn get width => integer().nullable()();
  IntColumn get height => integer().nullable()();
  TextColumn get transferId => text().nullable()();
  TextColumn get sha256 => text().nullable()();
}
