import 'package:flutter/material.dart';
import 'package:hoopsight/models/user_model.dart';
import 'package:hoopsight/models/friend_request_model.dart';
import 'package:hoopsight/services/auth_service.dart';
import 'package:hoopsight/services/user_service.dart';
import 'package:hoopsight/services/friend_service.dart';
import 'package:hoopsight/screens/user_profile_page.dart';

class FriendsPage extends StatefulWidget {
  const FriendsPage({super.key});

  @override
  State<FriendsPage> createState() => _FriendsPageState();
}

class _FriendsPageState extends State<FriendsPage> {
  final AuthService _authService = AuthService();
  final UserService _userService = UserService();
  final FriendService _friendService = FriendService();
  List<AppUser> _friends = [];
  List<FriendRequest> _pendingRequests = [];
  bool _isLoading = true;
  String? _currentUserId;
  int _pendingRequestsCount = 0;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final firebaseUser = _authService.currentUser;
    if (firebaseUser != null) {
      _currentUserId = firebaseUser.uid;
      await Future.wait([
        _loadFriends(),
        _loadPendingRequests(),
      ]);
    }
    setState(() => _isLoading = false);
  }

  Future<void> _loadFriends() async {
    if (_currentUserId != null) {
      final user = await _userService.getUser(_currentUserId!);
      if (user != null) {
        final friends = await _userService.getFriends(user.friendIds);
        // Filter out users with mutual blocks
        final filtered = friends.where((f) =>
            !user.blockedUserIds.contains(f.id) && !f.blockedUserIds.contains(user.id)).toList();
        setState(() {
          _friends = filtered;
        });
      }
    }
  }

  Future<void> _loadPendingRequests() async {
    if (_currentUserId != null) {
      final requests = await _friendService.getPendingRequests(_currentUserId!);
      setState(() {
        _pendingRequests = requests;
        _pendingRequestsCount = requests.length;
      });
    }
  }

  Future<void> _showFriendRequestDialog() async {
    await showDialog(
      context: context,
      builder: (context) => _FriendRequestDialog(
        currentUserId: _currentUserId!,
        onRequestSent: _loadData,
      ),
    );
  }

  Future<void> _acceptFriendRequest(FriendRequest request) async {
    try {
      await _friendService.acceptFriendRequest(request.id, _currentUserId!);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Accepted friend request from ${request.senderName}')),
      );
      _loadData();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to accept friend request')),
      );
    }
  }

  Future<void> _rejectFriendRequest(FriendRequest request) async {
    try {
      await _friendService.rejectFriendRequest(request.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Rejected friend request from ${request.senderName}')),
      );
      _loadData();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to reject friend request')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Friends'),
        actions: [
          Stack(
            children: [
              IconButton(
                icon: const Icon(Icons.person_add),
                onPressed: _showFriendRequestDialog,
              ),
              if (_pendingRequestsCount > 0)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 16,
                      minHeight: 16,
                    ),
                    child: Text(
                      '$_pendingRequestsCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Pending friend requests section
                if (_pendingRequests.isNotEmpty) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    color: theme.colorScheme.surface,
                    child: Text(
                      'Pending Friend Requests',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  ..._pendingRequests.map((request) => Card(
                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),
                            child: const Icon(Icons.person_add),
                          ),
                          title: Text(request.senderName),
                          subtitle: Text('Wants to be your friend'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.check, color: Colors.green),
                                onPressed: () => _acceptFriendRequest(request),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close, color: Colors.red),
                                onPressed: () => _rejectFriendRequest(request),
                              ),
                            ],
                          ),
                        ),
                      )),
                  const Divider(),
                ],
                // Friends list section
                Expanded(
                  child: _friends.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.people_outline,
                                size: 64,
                                color: theme.colorScheme.primary.withValues(alpha: 0.3),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'No Friends Yet',
                                style: theme.textTheme.titleLarge?.copyWith(
                                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Send friend requests to add friends',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: _friends.length,
                          itemBuilder: (context, index) {
                            final friend = _friends[index];
                            return Dismissible(
                              key: Key('friend_${friend.id}'),
                              direction: DismissDirection.endToStart,
                              background: Container(
                                alignment: Alignment.centerRight,
                                padding: const EdgeInsets.symmetric(horizontal: 20),
                                decoration: BoxDecoration(
                                  color: Colors.red.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    Icon(Icons.block, color: Colors.red.shade400),
                                    const SizedBox(width: 12),
                                    Text('Block / Unfriend', style: TextStyle(color: Colors.red.shade400, fontWeight: FontWeight.bold)),
                                  ],
                                ),
                              ),
                              confirmDismiss: (_) async {
                                await _showSwipeActions(friend);
                                return false; // do not actually dismiss
                              },
                              child: Card(
                                margin: const EdgeInsets.only(bottom: 12),
                                child: ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),
                                    child: friend.photoUrl != null
                                        ? ClipOval(
                                            child: Image.network(
                                              friend.photoUrl!,
                                              width: 40,
                                              height: 40,
                                              fit: BoxFit.cover,
                                            ),
                                          )
                                        : Icon(
                                            Icons.person,
                                            color: theme.colorScheme.primary,
                                          ),
                                  ),
                                  title: Text(friend.displayName),
                                  subtitle: Text(friend.skillLevel),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => UserProfilePage(userId: friend.id),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }

  Future<void> _showSwipeActions(AppUser friend) async {
    final userId = _currentUserId!;
    final isFriend = _friends.any((f) => f.id == friend.id);
    bool isBlocked = false;
    final user = await _userService.getUser(userId);
    if (user != null) {
      isBlocked = user.blockedUserIds.contains(friend.id);
    }

    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(isBlocked ? Icons.lock_open : Icons.block, color: Colors.red),
                  title: Text(isBlocked ? 'Unblock' : 'Block'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    try {
                      if (isBlocked) {
                        await _userService.unblockUser(userId, friend.id);
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User unblocked')));
                      } else {
                        await _userService.blockUser(userId, friend.id);
                        await _friendService.removeFriend(userId, friend.id);
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User blocked')));
                      }
                      await _loadFriends();
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
                    }
                  },
                ),
                if (isFriend)
                  ListTile(
                    leading: const Icon(Icons.person_off_outlined),
                    title: const Text('Unfriend'),
                    onTap: () async {
                      Navigator.pop(ctx);
                      try {
                        await _friendService.removeFriend(userId, friend.id);
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Friend removed')));
                        await _loadFriends();
                      } catch (e) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
                      }
                    },
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FriendRequestDialog extends StatefulWidget {
  final String currentUserId;
  final VoidCallback onRequestSent;

  const _FriendRequestDialog({
    required this.currentUserId,
    required this.onRequestSent,
  });

  @override
  State<_FriendRequestDialog> createState() => _FriendRequestDialogState();
}

class _FriendRequestDialogState extends State<_FriendRequestDialog> {
  final TextEditingController _searchController = TextEditingController();
  final UserService _userService = UserService();
  final FriendService _friendService = FriendService();
  List<AppUser> _searchResults = [];
  bool _isSearching = false;
  bool _hasSearched = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _searchUsers(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _hasSearched = false;
      });
      return;
    }

    setState(() => _isSearching = true);

    try {
      final results = await _userService.searchUsers(query.trim());
      final filteredResults = results.where((user) => user.id != widget.currentUserId).toList();
      
      setState(() {
        _searchResults = filteredResults;
        _isSearching = false;
        _hasSearched = true;
      });
    } catch (e) {
      setState(() {
        _isSearching = false;
        _hasSearched = true;
      });
    }
  }

  Future<void> _sendFriendRequest(AppUser user) async {
    try {
      // Get current user info for sending the friend request
      final currentUser = await _userService.getUser(widget.currentUserId);
      if (currentUser != null) {
        await _friendService.sendFriendRequest(
          widget.currentUserId,
          currentUser.displayName,
          currentUser.photoUrl,
          user.id,
          user.displayName,
        );
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Friend request sent to ${user.displayName}!')),
        );
        Navigator.pop(context);
        widget.onRequestSent();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to send friend request')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      child: Container(
        padding: const EdgeInsets.all(16),
        constraints: const BoxConstraints(maxHeight: 500),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Send Friend Request',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _searchController,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Search by username or email',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              textInputAction: TextInputAction.search,
              onChanged: (value) => _searchUsers(value),
              onSubmitted: (value) => _searchUsers(value),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _isSearching
                  ? const Center(child: CircularProgressIndicator())
                  : _hasSearched && _searchResults.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.person_search,
                                size: 48,
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'No users found',
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                                ),
                              ),
                            ],
                          ),
                        )
                      : !_hasSearched
                          ? Center(
                              child: Text(
                                'Start typing to search',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                                ),
                              ),
                            )
                          : ListView.builder(
                              itemCount: _searchResults.length,
                              itemBuilder: (context, index) {
                                final user = _searchResults[index];
                                return ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),
                                    child: user.photoUrl != null
                                        ? ClipOval(
                                            child: Image.network(
                                              user.photoUrl!,
                                              width: 40,
                                              height: 40,
                                              fit: BoxFit.cover,
                                            ),
                                          )
                                        : Icon(
                                            Icons.person,
                                            color: theme.colorScheme.primary,
                                          ),
                                  ),
                                  title: Text(user.displayName),
                                  subtitle: Text(user.skillLevel),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.send),
                                    onPressed: () => _sendFriendRequest(user),
                                  ),
                                  onTap: () {
                                    Navigator.pop(context);
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => UserProfilePage(userId: user.id),
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
    );
  }
}