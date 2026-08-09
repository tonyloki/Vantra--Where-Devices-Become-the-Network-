class VantraMessage {
  final String messageId;
  final String senderId;
  final String receiverId;
  final String text;
  final int timestamp;

  const VantraMessage({
    required this.messageId,
    required this.senderId,
    required this.receiverId,
    required this.text,
    required this.timestamp,
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
    );
  }
}
