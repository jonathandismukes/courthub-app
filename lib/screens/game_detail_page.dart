import 'package:flutter/material.dart';
import 'package:hoopsight/models/game_model.dart';
import 'package:hoopsight/models/group_model.dart';
import 'package:hoopsight/models/invite_model.dart';
import 'package:hoopsight/models/user_model.dart';
import 'package:hoopsight/services/auth_service.dart';
import 'package:hoopsight/services/game_service.dart';
import 'package:hoopsight/services/user_service.dart';
import 'package:hoopsight/services/group_service.dart';
import 'package:hoopsight/services/invite_service.dart';
import 'package:intl/intl.dart';
import 'package:hoopsight/utils/qr_utils.dart';
import 'package:hoopsight/widgets/qr_code_widget.dart';
import 'package:hoopsight/screens/game_qr_invite_page.dart';
import 'package:hoopsight/screens/game_checkin_qr_page.dart';

class GameDetailPage extends StatefulWidget {
  final Game game;

  const GameDetailPage({super.key, required this.game});

  @override
  State<GameDetailPage> createState() => _GameDetailPageState();
}

class _GameDetailPageState extends State<GameDetailPage> {
  final AuthService _authService = AuthService();
  final GameService _gameService = GameService();
  final UserService _userService = UserService();
  final GroupService _groupService = GroupService();
  final InviteService _inviteService = InviteService();
  late Game _game;
  bool _isLoading = false;
  
  // Invite related state
  List<AppUser> _friends = [];
  List<FriendGroup> _groups = [];
  bool _isLoadingInviteData = false;
  AppUser? _currentAppUser;

  @override
  void initState() {
    super.initState();
    _game = widget.game;
    final user = _authService.currentUser;
    if (user != null && _game.organizerId == user.uid) {
      _loadInviteData();
    }
  }

  Future<void> _loadInviteData() async {
    final user = _authService.currentUser;
    if (user == null) return;

    setState(() => _isLoadingInviteData = true);

    try {
      final appUser = await _userService.getUser(user.uid);
      _currentAppUser = appUser;
      final groups = await _groupService.getUserGroups(user.uid);
      List<AppUser> friends = [];
      if (appUser != null && appUser.friendIds.isNotEmpty) {
        final rawFriends = await _userService.getFriends(appUser.friendIds);
        // Filter out any mutually blocked relationships
        friends = rawFriends.where((f) {
          final blockedByCurrent = appUser.blockedUserIds.contains(f.id);
          final blocksCurrent = f.blockedUserIds.contains(appUser.id);
          return !(blockedByCurrent || blocksCurrent);
        }).toList();
      }

      setState(() {
        _friends = friends;
        _groups = groups;
      });
    } catch (e) {
      debugPrint('Error loading invite data: $e');
    } finally {
      setState(() => _isLoadingInviteData = false);
    }
  }

  bool get _isUserInGame {
    final user = _authService.currentUser;
    return user != null && _game.playerIds.contains(user.uid);
  }

  bool get _isGameOrganizer {
    final user = _authService.currentUser;
    return user != null && _game.organizerId == user.uid;
  }


  Future<void> _joinGame() async {
    final user = _authService.currentUser;
    if (user == null) return;

    final appUser = await _userService.getUser(user.uid);
    if (appUser == null) return;

    setState(() => _isLoading = true);

    try {
      await _gameService.joinGame(_game.id, user.uid, appUser.displayName);
      final updatedGame = await _gameService.getGame(_game.id);
      if (updatedGame != null) {
        setState(() {
          _game = updatedGame;
          _isLoading = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Joined game successfully!')),
          );
        }
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to join game: $e')),
        );
      }
    }
  }

  Future<void> _leaveGame() async {
    final user = _authService.currentUser;
    if (user == null) return;

    final appUser = await _userService.getUser(user.uid);
    if (appUser == null) return;

    setState(() => _isLoading = true);

    try {
      await _gameService.leaveGame(_game.id, user.uid, appUser.displayName);
      final updatedGame = await _gameService.getGame(_game.id);
      if (updatedGame != null) {
        setState(() {
          _game = updatedGame;
          _isLoading = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Left game successfully')),
          );
        }
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to leave game: $e')),
        );
      }
    }
  }

  Future<void> _showStartPlayingDialog() async {
    if (_friends.isEmpty && _groups.isEmpty) {
      _startPlayingNow();
      return;
    }

    final selectedFriendIds = <String>{};
    final selectedGroupIds = <String>{};

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Start Playing Now'),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Notify friends and groups that the game is starting:'),
                    const SizedBox(height: 16),
                    if (_isLoadingInviteData)
                      const Center(child: CircularProgressIndicator())
                    else ...[
                      if (_friends.isNotEmpty) ...[
                        const Text('Friends:', style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 200),
                          child: SingleChildScrollView(
                            child: Column(
                              children: _friends.map((friend) => CheckboxListTile(
                                title: Text(friend.displayName),
                                value: selectedFriendIds.contains(friend.id),
                                onChanged: (bool? value) {
                                  setDialogState(() {
                                    if (value == true) {
                                      selectedFriendIds.add(friend.id);
                                    } else {
                                      selectedFriendIds.remove(friend.id);
                                    }
                                  });
                                },
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                              )).toList(),
                            ),
                          ),
                        ),
                        if (_groups.isNotEmpty) const SizedBox(height: 16),
                      ],
                      if (_groups.isNotEmpty) ...[
                        const Text('Groups:', style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 200),
                          child: SingleChildScrollView(
                            child: Column(
                              children: _groups.map((group) => CheckboxListTile(
                                title: Text(group.name),
                                subtitle: Text('${group.memberNames.length} members'),
                                value: selectedGroupIds.contains(group.id),
                                onChanged: (bool? value) {
                                  setDialogState(() {
                                    if (value == true) {
                                      selectedGroupIds.add(group.id);
                                    } else {
                                      selectedGroupIds.remove(group.id);
                                    }
                                  });
                                },
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                              )).toList(),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _startPlayingNow(
                      selectedFriendIds: selectedFriendIds,
                      selectedGroupIds: selectedGroupIds,
                    );
                  },
                  child: const Text('Start Game'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _startPlayingNow({
    Set<String> selectedFriendIds = const {},
    Set<String> selectedGroupIds = const {},
  }) async {
    final user = _authService.currentUser;
    if (user == null) return;

    final appUser = await _userService.getUser(user.uid);
    if (appUser == null) return;

    setState(() => _isLoading = true);

    try {
      // Update game status to active
      final updatedGame = _game.copyWith(status: GameStatus.active);
      await _gameService.updateGame(updatedGame);

      // Send now playing invites if any are selected
      await _sendNowPlayingInvites(user.uid, appUser.displayName, selectedFriendIds, selectedGroupIds);

      setState(() {
        _game = updatedGame;
        _isLoading = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Game started! Notifications sent.')),
        );
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start game: $e')),
        );
      }
    }
  }

  Future<void> _sendNowPlayingInvites(
    String senderId,
    String senderName,
    Set<String> selectedFriendIds,
    Set<String> selectedGroupIds,
  ) async {
    final invitedUserIds = <String>[];
    final invitedUserNames = <String>[];

    // Add selected friends
    for (final friendId in selectedFriendIds) {
      final friend = _friends.firstWhere((f) => f.id == friendId);
      invitedUserIds.add(friendId);
      invitedUserNames.add(friend.displayName);
    }

    // Add members from selected groups
    for (final groupId in selectedGroupIds) {
      final group = _groups.firstWhere((g) => g.id == groupId);
      invitedUserIds.addAll(group.memberIds);
      invitedUserNames.addAll(group.memberNames);
    }

    // Remove duplicates and sender
    final uniqueUserIds = invitedUserIds.toSet().where((id) => id != senderId).toList();
    final uniqueUserNames = <String>[];
    final addedIds = <String>{};
    
    for (int i = 0; i < invitedUserIds.length; i++) {
      if (!addedIds.contains(invitedUserIds[i]) && invitedUserIds[i] != senderId) {
        addedIds.add(invitedUserIds[i]);
        uniqueUserNames.add(invitedUserNames[i]);
      }
    }

    // Enforce: interactions limited to invited friends only and not blocked either way
    final senderFriends = _currentAppUser?.friendIds.toSet() ?? <String>{};
    final senderBlocked = _currentAppUser?.blockedUserIds.toSet() ?? <String>{};
    final filteredIds = <String>[];
    final filteredNames = <String>[];
    for (int i = 0; i < uniqueUserIds.length; i++) {
      final uid = uniqueUserIds[i];
      if (!senderFriends.contains(uid)) continue;
      if (senderBlocked.contains(uid)) continue;
      // also ensure the target hasn't blocked the sender (from loaded friends if present)
      final friend = _friends.where((f) => f.id == uid).cast<AppUser?>().firstWhere((f) => f != null, orElse: () => null);
      if (friend != null && friend.blockedUserIds.contains(senderId)) continue;
      filteredIds.add(uid);
      filteredNames.add(uniqueUserNames[i]);
    }

    if (filteredIds.isNotEmpty) {
      final invite = GameInvite(
        id: '${_game.id}_nowplaying_${DateTime.now().millisecondsSinceEpoch}',
        gameId: _game.id,
        gameName: '${_game.parkName} Game',
        parkId: _game.parkId,
        parkName: _game.parkName,
        courtId: _game.courtId,
        courtNumber: 1, // Default court number
        sportType: _game.sportType,
        senderId: senderId,
        senderName: senderName,
        invitedUserIds: filteredIds,
        invitedUserNames: filteredNames,
        type: InviteType.nowPlaying,
        scheduledTime: _game.scheduledTime,
        createdAt: DateTime.now(),
      );

      await _inviteService.sendGameInvites(invite);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateFormat = DateFormat('EEEE, MMMM dd, yyyy • h:mm a');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Game Details'),
      ),
      floatingActionButton: _isGameOrganizer && _game.status == GameStatus.scheduled
          ? FloatingActionButton.extended(
              onPressed: _isLoading ? null : _showStartPlayingDialog,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start Playing Now'),
            )
          : null,
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [theme.colorScheme.primary, theme.colorScheme.secondary],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _game.parkName,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    dateFormat.format(_game.scheduledTime),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _InfoRow(
                    icon: Icons.person,
                    label: 'Organized by',
                    value: _game.organizerName,
                  ),
                  const SizedBox(height: 16),
                  _InfoRow(
                    icon: Icons.people,
                    label: 'Players',
                    value: '${_game.playerIds.length}/${_game.maxPlayers}',
                  ),
                  if (_game.skillLevel != null) ...[
                    const SizedBox(height: 16),
                    _InfoRow(
                      icon: Icons.star,
                      label: 'Skill Level',
                      value: _game.skillLevel!,
                    ),
                  ],
                  if (_game.notes != null && _game.notes!.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text(
                      'Notes',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(_game.notes!),
                  ],
                  const SizedBox(height: 24),
                  Text(
                    'Players (${_game.playerNames.length})',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ..._game.playerNames.map((name) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Icon(Icons.person, size: 20, color: theme.colorScheme.primary),
                            const SizedBox(width: 8),
                            Text(name),
                          ],
                        ),
                      )),
                  const SizedBox(height: 32),
                  // QR actions
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => GameQrInvitePage(game: _game),
                              ),
                            );
                          },
                          icon: const Icon(Icons.qr_code),
                          label: const Text('Invite via QR'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            debugPrint('[CheckInQR] open requested for game ${_game.id}');
                            final shortestSide = MediaQuery.of(context).size.shortestSide;
                            final isPhone = shortestSide < 600;
                            if (!mounted) return;

                            if (isPhone) {
                              // Full-screen experience on phones
                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => GameCheckInQrPage(gameId: _game.id),
                                ),
                              );
                              debugPrint('[CheckInQR] full-screen page closed for game ${_game.id}');
                              return;
                            }

                            // Bottom sheet on tablets/desktop/web
                            final data = QrUtils.buildGameCheckInPayload(_game.id);
                            await showModalBottomSheet(
                              context: context,
                              isScrollControlled: false,
                              showDragHandle: true,
                              backgroundColor: Theme.of(context).colorScheme.surface,
                              builder: (sheetContext) {
                                return SafeArea(
                                  child: Center(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(maxWidth: 480),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              'Game Check-in QR',
                                              style: Theme.of(sheetContext).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                                            ),
                                            const SizedBox(height: 16),
                                            // Explicit size ensures no zero-size render boxes on web
                                            QRCodeWidget(data: data, size: 240),
                                            const SizedBox(height: 12),
                                            Text(
                                              'Players scan to check in to this game',
                                              style: Theme.of(sheetContext).textTheme.bodySmall,
                                              textAlign: TextAlign.center,
                                            ),
                                            const SizedBox(height: 12),
                                            SizedBox(
                                              width: double.infinity,
                                              child: OutlinedButton(
                                                onPressed: () => Navigator.of(sheetContext).maybePop(),
                                                child: const Text('Close'),
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            );
                            debugPrint('[CheckInQR] bottom sheet closed for game ${_game.id}');
                          },
                          icon: const Icon(Icons.qr_code_2),
                          label: const Text('Check-in QR'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_game.status == GameStatus.scheduled)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _isLoading
                            ? null
                            : _isUserInGame
                                ? _leaveGame
                                : _game.playerIds.length < _game.maxPlayers
                                    ? _joinGame
                                    : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isUserInGame
                              ? theme.colorScheme.error
                              : theme.colorScheme.primary,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: _isLoading
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Text(
                                _isUserInGame
                                    ? 'Leave Game'
                                    : _game.playerIds.length >= _game.maxPlayers
                                        ? 'Game Full'
                                        : 'Join Game',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                      ),
                    )
                  else if (_game.status == GameStatus.active)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.green),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.play_circle_fill, color: Colors.green, size: 24),
                          const SizedBox(width: 8),
                          const Text(
                            'Game is Now Active!',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.green,
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (_game.status == GameStatus.completed)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.blue.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.blue),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.check_circle, color: Colors.blue, size: 24),
                          SizedBox(width: 8),
                          Text(
                            'Game Completed',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.blue,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Icon(icon, color: theme.colorScheme.primary),
        const SizedBox(width: 12),
        Text(
          '$label: ',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
          ),
        ),
        Text(
          value,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}
