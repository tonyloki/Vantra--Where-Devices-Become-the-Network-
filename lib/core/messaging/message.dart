import 'package:vantra/core/models/message_status.dart';

class VantraMessage {
  final String messageId;
  final String senderId;
  final String receiverId;
  final String text;
  final int timestamp;
  final MessageStatus status;
  final int retryCount;

  const VantraMessage({
    required this.messageId,
    required this.senderId,
    required this.receiverId,
    required this.text,
    required this.timestamp,
    this.status = MessageStatus.sent,
    this.retryCount = 0,
  });

  Map<String, dynamic> toJson() => {
    'type': 'TEXT',
    'messageId': messageId,
    'senderId': senderId,
    'receiverId': receiverId,
    'text': text,
    'timestamp': timestamp,
  };

  factory VantraMessage.fromJson(Map<String, dynamic> json) {
    return VantraMessage(
      messageId: json['messageId'] as String,
      senderId: json['senderId'] as String,
      receiverId: json['receiverId'] as String,
      text: json['text'] as String,
      timestamp: json['timestamp'] as int,
      status: MessageStatus.received,
      retryCount: 0,
    );
  }

  VantraMessage copyWith({
    String? messageId,
    String? senderId,
    String? receiverId,
    String? text,
    int? timestamp,
    MessageStatus? status,
    int? retryCount,
  }) {
    return VantraMessage(
      messageId: messageId ?? this.messageId,
      senderId: senderId ?? this.senderId,
      receiverId: receiverId ?? this.receiverId,
      text: text ?? this.text,
      timestamp: timestamp ?? this.timestamp,
      status: status ?? this.status,
      retryCount: retryCount ?? this.retryCount,
    );
  }
}
