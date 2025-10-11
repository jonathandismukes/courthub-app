class GroupMessage {
  final String id;
  final String groupId;
  final String senderId;
  final String senderName;
  final String? senderPhotoUrl;
  final String text;
  final DateTime createdAt;
  final bool containsProfanity;
  final bool looksLikeSpam;
  final List<String> flaggedKeywords;
  final bool isDeleted;

  const GroupMessage({
    required this.id,
    required this.groupId,
    required this.senderId,
    required this.senderName,
    this.senderPhotoUrl,
    required this.text,
    required this.createdAt,
    this.containsProfanity = false,
    this.looksLikeSpam = false,
    this.flaggedKeywords = const [],
    this.isDeleted = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'groupId': groupId,
        'senderId': senderId,
        'senderName': senderName,
        'senderPhotoUrl': senderPhotoUrl,
        'text': text,
        'createdAt': createdAt.toIso8601String(),
        'containsProfanity': containsProfanity,
        'looksLikeSpam': looksLikeSpam,
        'flaggedKeywords': flaggedKeywords,
        'isDeleted': isDeleted,
      };

  factory GroupMessage.fromJson(Map<String, dynamic> json) => GroupMessage(
        id: json['id'] ?? '',
        groupId: json['groupId'] ?? '',
        senderId: json['senderId'] ?? '',
        senderName: json['senderName'] ?? 'Unknown',
        senderPhotoUrl: json['senderPhotoUrl'],
        text: json['text'] ?? '',
        createdAt: json['createdAt'] != null
            ? DateTime.parse(json['createdAt'])
            : DateTime.now(),
        containsProfanity: json['containsProfanity'] ?? false,
        looksLikeSpam: json['looksLikeSpam'] ?? false,
        flaggedKeywords:
            List<String>.from(json['flaggedKeywords'] ?? const <String>[]),
        isDeleted: json['isDeleted'] ?? false,
      );
}
