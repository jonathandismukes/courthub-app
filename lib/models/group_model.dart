class FriendGroup {
  final String id;
  final String name;
  final String creatorId;
  final List<String> memberIds;
  final List<String> memberNames;
  final DateTime createdAt;
  final DateTime updatedAt;

  FriendGroup({
    required this.id,
    required this.name,
    required this.creatorId,
    this.memberIds = const [],
    this.memberNames = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'creatorId': creatorId,
    'memberIds': memberIds,
    'memberNames': memberNames,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory FriendGroup.fromJson(Map<String, dynamic> json) => FriendGroup(
    id: json['id'] ?? '',
    name: json['name'] ?? 'Unnamed Group',
    creatorId: json['creatorId'] ?? '',
    memberIds: List<String>.from(json['memberIds'] ?? []),
    memberNames: List<String>.from(json['memberNames'] ?? []),
    createdAt: json['createdAt'] != null ? DateTime.parse(json['createdAt']) : DateTime.now(),
    updatedAt: json['updatedAt'] != null ? DateTime.parse(json['updatedAt']) : DateTime.now(),
  );

  FriendGroup copyWith({
    String? id,
    String? name,
    String? creatorId,
    List<String>? memberIds,
    List<String>? memberNames,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => FriendGroup(
    id: id ?? this.id,
    name: name ?? this.name,
    creatorId: creatorId ?? this.creatorId,
    memberIds: memberIds ?? this.memberIds,
    memberNames: memberNames ?? this.memberNames,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}
