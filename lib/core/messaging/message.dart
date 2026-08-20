import 'package:vantra/core/models/message_status.dart';

class VantraMessage {
  final String messageId;
  final String senderId;
  final String receiverId;
  final String text;
  final int timestamp;
  final MessageStatus status;
  final int retryCount;
  final String type;
  final String? mediaPath;
  final String? mimeType;
  final String? fileName;
  final int? fileSize;
  final int? width;
  final int? height;
  final String? transferId;
  final String? sha256;
  final int? duration;
  final String? groupId;

  const VantraMessage({
    required this.messageId,
    required this.senderId,
    required this.receiverId,
    required this.text,
    required this.timestamp,
    this.status = MessageStatus.sent,
    this.retryCount = 0,
    this.type = 'TEXT',
    this.mediaPath,
    this.mimeType,
    this.fileName,
    this.fileSize,
    this.width,
    this.height,
    this.transferId,
    this.sha256,
    this.duration,
    this.groupId,
  });

  Map<String, dynamic> toJson() => {
    'type': type,
    'messageId': messageId,
    'senderId': senderId,
    'receiverId': receiverId,
    'text': text,
    'timestamp': timestamp,
    'mediaPath': mediaPath,
    'mimeType': mimeType,
    'fileName': fileName,
    'fileSize': fileSize,
    'width': width,
    'height': height,
    'transferId': transferId,
    'sha256': sha256,
    'duration': duration,
    'groupId': groupId,
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
      type: json['type'] as String? ?? 'TEXT',
      mediaPath: json['mediaPath'] as String?,
      mimeType: json['mimeType'] as String?,
      fileName: json['fileName'] as String?,
      fileSize: json['fileSize'] as int?,
      width: json['width'] as int?,
      height: json['height'] as int?,
      transferId: json['transferId'] as String?,
      sha256: json['sha256'] as String?,
      duration: json['duration'] as int?,
      groupId: json['groupId'] as String?,
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
    String? type,
    String? mediaPath,
    String? mimeType,
    String? fileName,
    int? fileSize,
    int? width,
    int? height,
    String? transferId,
    String? sha256,
    int? duration,
    String? groupId,
  }) {
    return VantraMessage(
      messageId: messageId ?? this.messageId,
      senderId: senderId ?? this.senderId,
      receiverId: receiverId ?? this.receiverId,
      text: text ?? this.text,
      timestamp: timestamp ?? this.timestamp,
      status: status ?? this.status,
      retryCount: retryCount ?? this.retryCount,
      type: type ?? this.type,
      mediaPath: mediaPath ?? this.mediaPath,
      mimeType: mimeType ?? this.mimeType,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      width: width ?? this.width,
      height: height ?? this.height,
      transferId: transferId ?? this.transferId,
      sha256: sha256 ?? this.sha256,
      duration: duration ?? this.duration,
      groupId: groupId ?? this.groupId,
    );
  }
}
