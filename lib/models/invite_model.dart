import 'package:hoopsight/models/park_model.dart';

enum InviteType { scheduledGame, nowPlaying }

class GameInvite {
  final String id;
  final String gameId;
  final String gameName;
  final String parkId;
  final String parkName;
  final String courtId;
  final int courtNumber;
  final SportType sportType;
  final String senderId;
  final String senderName;
  final List<String> invitedUserIds;
  final List<String> invitedUserNames;
  final InviteType type;
  final DateTime scheduledTime;
  final DateTime createdAt;

  GameInvite({
    required this.id,
    required this.gameId,
    required this.gameName,
    required this.parkId,
    required this.parkName,
    required this.courtId,
    required this.courtNumber,
    this.sportType = SportType.basketball,
    required this.senderId,
    required this.senderName,
    this.invitedUserIds = const [],
    this.invitedUserNames = const [],
    required this.type,
    required this.scheduledTime,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'gameId': gameId,
    'gameName': gameName,
    'parkId': parkId,
    'parkName': parkName,
    'courtId': courtId,
    'courtNumber': courtNumber,
    'sportType': sportType.toString().split('.').last,
    'senderId': senderId,
    'senderName': senderName,
    'invitedUserIds': invitedUserIds,
    'invitedUserNames': invitedUserNames,
    'type': type.toString().split('.').last,
    'scheduledTime': scheduledTime.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
  };

  factory GameInvite.fromJson(Map<String, dynamic> json) => GameInvite(
    id: json['id'] ?? '',
    gameId: json['gameId'] ?? '',
    gameName: json['gameName'] ?? '',
    parkId: json['parkId'] ?? '',
    parkName: json['parkName'] ?? '',
    courtId: json['courtId'] ?? '',
    courtNumber: json['courtNumber'] ?? 1,
    sportType: SportType.values.firstWhere(
      (e) => e.toString().split('.').last == json['sportType'],
      orElse: () => SportType.basketball,
    ),
    senderId: json['senderId'] ?? '',
    senderName: json['senderName'] ?? 'Unknown',
    invitedUserIds: List<String>.from(json['invitedUserIds'] ?? []),
    invitedUserNames: List<String>.from(json['invitedUserNames'] ?? []),
    type: InviteType.values.firstWhere(
      (e) => e.toString().split('.').last == json['type'],
      orElse: () => InviteType.scheduledGame,
    ),
    scheduledTime: json['scheduledTime'] != null ? DateTime.parse(json['scheduledTime']) : DateTime.now(),
    createdAt: json['createdAt'] != null ? DateTime.parse(json['createdAt']) : DateTime.now(),
  );
}
