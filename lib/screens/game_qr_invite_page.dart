import 'package:flutter/material.dart';
import 'package:hoopsight/models/game_model.dart';
import 'package:hoopsight/models/group_model.dart';
import 'package:hoopsight/models/invite_model.dart';
import 'package:hoopsight/models/user_model.dart';
import 'package:hoopsight/services/auth_service.dart';
import 'package:hoopsight/services/user_service.dart';
import 'package:hoopsight/services/group_service.dart';
import 'package:hoopsight/services/invite_service.dart';
import 'package:hoopsight/utils/qr_utils.dart';
import 'package:hoopsight/widgets/qr_code_widget.dart';

class GameQrInvitePage extends StatefulWidget {
  final Game game;

  const GameQrInvitePage({super.key, required this.game});

  @override
  State<GameQrInvitePage> createState() => _GameQrInvitePageState();
}

class _GameQrInvitePageState extends State<GameQrInvitePage> {
  final AuthService _authService = AuthService();
  final UserService _userService = UserService();
  final GroupService _groupService = GroupService();
  final InviteService _inviteService = InviteService();

  List<AppUser> _friends = [];
  List<FriendGroup> _groups = [];
  bool _isLoadingInviteData = false;

  bool get _isOrganizer {
    final user = _authService.currentUser;
    return user != null && user.uid == widget.game.organizerId;
  }

  @override
  void initState() {
    super.initState();
    if (_isOrganizer) {
      _loadInviteData();
    }
  }

  Future<void> _loadInviteData() async {
    final user = _authService.currentUser;
    if (user == null) return;

    setState(() => _isLoadingInviteData = true);
    try {
      final appUser = await _userService.getUser(user.uid);
      List<AppUser> friends = [];
      if (appUser != null && appUser.friendIds.isNotEmpty) {
        final rawFriends = await _userService.getFriends(appUser.friendIds);
        // Filter mutual blocks
        friends = rawFriends.where((f) {
          final blockedByCurrent = appUser.blockedUserIds.contains(f.id);
          final blocksCurrent = f.blockedUserIds.contains(appUser.id);
          return !(blockedByCurrent || blocksCurrent);
        }).toList();
      }
      final groups = await _groupService.getUserGroups(user.uid);

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

  Future<void> _openInviteDialog() async {
    if (!_isOrganizer) return;

    // Ensure data is ready BEFORE opening the dialog to avoid a stuck spinner.
    // If a load is already in progress (e.g., from initState), wait for it to finish.
    if (_isLoadingInviteData) {
      // Poll briefly until loading completes.
      while (_isLoadingInviteData) {
        if (!mounted) return;
        await Future.delayed(const Duration(milliseconds: 80));
      }
    } else if (_friends.isEmpty && _groups.isEmpty) {
      // Not loading and nothing loaded yet; fetch now.
      await _loadInviteData();
    }

    final selectedFriendIds = <String>{};
    final selectedGroupIds = <String>{};

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Invite Friends & Groups'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_isLoadingInviteData)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                  if (_friends.isNotEmpty) ...[
                    const Text('Friends', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: SingleChildScrollView(
                        child: Column(
                          children: _friends.map((friend) => CheckboxListTile(
                            title: Text(friend.displayName),
                            value: selectedFriendIds.contains(friend.id),
                            onChanged: (v) {
                              setDialogState(() {
                                if (v == true) {
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
                    const Text('Groups', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: SingleChildScrollView(
                        child: Column(
                          children: _groups.map((group) => CheckboxListTile(
                            title: Text(group.name),
                            subtitle: Text('${group.memberNames.length} members'),
                            value: selectedGroupIds.contains(group.id),
                            onChanged: (v) {
                              setDialogState(() {
                                if (v == true) {
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
                  if (_friends.isEmpty && _groups.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('No friends or groups to invite.'),
                    ),
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
              onPressed: () async {
                Navigator.pop(context);
                await _sendScheduledInvites(selectedFriendIds, selectedGroupIds);
              },
              child: const Text('Send Invites'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendScheduledInvites(Set<String> selectedFriendIds, Set<String> selectedGroupIds) async {
    final user = _authService.currentUser;
    if (user == null) return;

    final invitedUserIds = <String>[];
    final invitedUserNames = <String>[];

    // Add selected friends
    for (final friendId in selectedFriendIds) {
      final friend = _friends.firstWhere((f) => f.id == friendId);
      invitedUserIds.add(friendId);
      invitedUserNames.add(friend.displayName);
    }

    // Add selected groups
    for (final groupId in selectedGroupIds) {
      final group = _groups.firstWhere((g) => g.id == groupId);
      invitedUserIds.addAll(group.memberIds);
      invitedUserNames.addAll(group.memberNames);
    }

    // Remove duplicates and sender
    final uniqueUserIds = invitedUserIds.toSet().where((id) => id != user.uid).toList();
    final uniqueUserNames = <String>[];
    final addedIds = <String>{};
    for (int i = 0; i < invitedUserIds.length; i++) {
      if (!addedIds.contains(invitedUserIds[i]) && invitedUserIds[i] != user.uid) {
        addedIds.add(invitedUserIds[i]);
        uniqueUserNames.add(invitedUserNames[i]);
      }
    }

    // Enforce: only existing friends and not blocked either way
    final sender = await _userService.getUser(user.uid);
    final senderFriends = sender?.friendIds.toSet() ?? <String>{};
    final senderBlocked = sender?.blockedUserIds.toSet() ?? <String>{};
    final filteredIds = <String>[];
    final filteredNames = <String>[];
    for (int i = 0; i < uniqueUserIds.length; i++) {
      final uid = uniqueUserIds[i];
      if (!senderFriends.contains(uid)) continue;
      if (senderBlocked.contains(uid)) continue;
      final friend = _friends.where((f) => f.id == uid).cast<AppUser?>().firstWhere((f) => f != null, orElse: () => null);
      if (friend != null && friend.blockedUserIds.contains(user.uid)) continue;
      filteredIds.add(uid);
      filteredNames.add(uniqueUserNames[i]);
    }

    if (filteredIds.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No eligible friends to invite.')),
        );
      }
      return;
    }

    final invite = GameInvite(
      id: '${widget.game.id}_invite_${DateTime.now().millisecondsSinceEpoch}',
      gameId: widget.game.id,
      gameName: '${widget.game.parkName} Game',
      parkId: widget.game.parkId,
      parkName: widget.game.parkName,
      courtId: widget.game.courtId,
      courtNumber: 1,
      sportType: widget.game.sportType,
      senderId: user.uid,
      senderName: (await _userService.getUser(user.uid))?.displayName ?? 'Organizer',
      invitedUserIds: filteredIds,
      invitedUserNames: filteredNames,
      type: InviteType.scheduledGame,
      scheduledTime: widget.game.scheduledTime,
      createdAt: DateTime.now(),
    );

    await _inviteService.sendGameInvites(invite);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Invites sent to ${filteredIds.length} ${filteredIds.length == 1 ? 'friend' : 'friends'}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = QrUtils.buildGameInvitePayload(widget.game.id);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Invite via QR'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    QRCodeWidget(data: data),
                    const SizedBox(height: 16),
                    Text(
                      'Have friends scan to join this game',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.game.parkName,
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              if (_isOrganizer)
                SafeArea(
                  top: false,
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _openInviteDialog,
                      icon: const Icon(Icons.person_add),
                      label: const Text('Invite Friends'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
