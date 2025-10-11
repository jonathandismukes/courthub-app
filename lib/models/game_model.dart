import 'package:hoopsight/models/park_model.dart';

enum GameStatus { scheduled, active, completed, cancelled }

class Game {
  final String id;
  final String parkId;
  final String parkName;
  final String courtId;
  final SportType sportType;
  final String organizerId;
  final String organizerName;
  final DateTime scheduledTime;
  final int maxPlayers;
  final List<String> playerIds;
  final List<String> playerNames;
  final GameStatus status;
  final String? skillLevel;
  final String? notes;
  final DateTime createdAt;
  final String? qrCodeData;

  Game({
    required this.id,
    required this.parkId,
    required this.parkName,
    required this.courtId,
    this.sportType = SportType.basketball,
    required this.organizerId,
    required this.organizerName,
    required this.scheduledTime,
    this.maxPlayers = 10,
    this.playerIds = const [],
    this.playerNames = const [],
    this.status = GameStatus.scheduled,
    this.skillLevel,
    this.notes,
    required this.createdAt,
    this.qrCodeData,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'parkId': parkId,
    'parkName': parkName,
    'courtId': courtId,
    'sportType': sportType.toString().split('.').last,
    'organizerId': organizerId,
    'organizerName': organizerName,
    'scheduledTime': scheduledTime.toIso8601String(),
    'maxPlayers': maxPlayers,
    'playerIds': playerIds,
    'playerNames': playerNames,
    'status': status.toString().split('.').last,
    'skillLevel': skillLevel,
    'notes': notes,
    'createdAt': createdAt.toIso8601String(),
    'qrCodeData': qrCodeData,
  };

  factory Game.fromJson(Map<String, dynamic> json) => Game(
    id: json['id'] ?? '',
    parkId: json['parkId'] ?? '',
    parkName: json['parkName'] ?? '',
    courtId: json['courtId'] ?? '',
    sportType: SportType.values.firstWhere(
      (e) => e.toString().split('.').last == json['sportType'],
      orElse: () => SportType.basketball,
    ),
    organizerId: json['organizerId'] ?? '',
    organizerName: json['organizerName'] ?? '',
    scheduledTime: json['scheduledTime'] != null ? DateTime.parse(json['scheduledTime']) : DateTime.now(),
    maxPlayers: json['maxPlayers'] ?? 10,
    playerIds: List<String>.from(json['playerIds'] ?? []),
    playerNames: List<String>.from(json['playerNames'] ?? []),
    status: GameStatus.values.firstWhere(
      (e) => e.toString().split('.').last == json['status'],
      orElse: () => GameStatus.scheduled,
    ),
    skillLevel: json['skillLevel'],
    notes: json['notes'],
    createdAt: json['createdAt'] != null ? DateTime.parse(json['createdAt']) : DateTime.now(),
    qrCodeData: json['qrCodeData'],
  );

  Game copyWith({
    String? id,
    String? parkId,
    String? parkName,
    String? courtId,
    SportType? sportType,
    String? organizerId,
    String? organizerName,
    DateTime? scheduledTime,
    int? maxPlayers,
    List<String>? playerIds,
    List<String>? playerNames,
    GameStatus? status,
    String? skillLevel,
    String? notes,
    DateTime? createdAt,
    String? qrCodeData,
  }) => Game(
    id: id ?? this.id,
    parkId: parkId ?? this.parkId,
    parkName: parkName ?? this.parkName,
    courtId: courtId ?? this.courtId,
    sportType: sportType ?? this.sportType,
    organizerId: organizerId ?? this.organizerId,
    organizerName: organizerName ?? this.organizerName,
    scheduledTime: scheduledTime ?? this.scheduledTime,
    maxPlayers: maxPlayers ?? this.maxPlayers,
    playerIds: playerIds ?? this.playerIds,
    playerNames: playerNames ?? this.playerNames,
    status: status ?? this.status,
    skillLevel: skillLevel ?? this.skillLevel,
    notes: notes ?? this.notes,
    createdAt: createdAt ?? this.createdAt,
    qrCodeData: qrCodeData ?? this.qrCodeData,
  );
}
