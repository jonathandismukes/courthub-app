import 'package:flutter/material.dart';
import 'package:hoopsight/models/group_model.dart';
import 'package:hoopsight/models/user_model.dart';
import 'package:hoopsight/services/auth_service.dart';
import 'package:hoopsight/services/group_service.dart';
import 'package:hoopsight/services/user_service.dart';
import 'package:hoopsight/screens/group_chat_page.dart';

class GroupsPage extends StatefulWidget {
  const GroupsPage({super.key});

  @override
  State<GroupsPage> createState() => _GroupsPageState();
}

class _GroupsPageState extends State<GroupsPage> {
  final AuthService _authService = AuthService();
  final GroupService _groupService = GroupService();
  final UserService _userService = UserService();
  List<FriendGroup> _groups = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadGroups();
  }

  Future<void> _loadGroups() async {
    final user = _authService.currentUser;
    if (user != null) {
      final groups = await _groupService.getUserGroups(user.uid);
      setState(() {
        _groups = groups;
        _isLoading = false;
      });
    } else {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _showCreateGroupDialog() async {
    final user = _authService.currentUser;
    if (user == null) return;

    final appUser = await _userService.getUser(user.uid);
    if (appUser == null) return;

    final nameController = TextEditingController();
    final friends = await _userService.getFriends(appUser.friendIds);
    final selectedFriends = <String, String>{};

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Create Group'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Group Name',
                    hintText: 'Tuesday Squad',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) {
                    // Rebuild the dialog to update the enabled state of the Create button
                    setDialogState(() {});
                  },
                ),
                const SizedBox(height: 16),
                Text(
                  'Select Friends',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                if (friends.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Add friends first to create a group',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  )
                else
                  ...friends.map((friend) => CheckboxListTile(
                    title: Text(friend.displayName),
                    value: selectedFriends.containsKey(friend.id),
                    onChanged: (value) {
                      setDialogState(() {
                        if (value == true) {
                          selectedFriends[friend.id] = friend.displayName;
                        } else {
                          selectedFriends.remove(friend.id);
                        }
                      });
                    },
                    contentPadding: EdgeInsets.zero,
                  )),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: nameController.text.trim().isEmpty
                  ? null
                  : () async {
                      final memberIds = <String>{user.uid, ...selectedFriends.keys}.toList();
                      final memberNames = <String>{appUser.displayName, ...selectedFriends.values}.toList();

                      final group = FriendGroup(
                        id: '${user.uid}_${DateTime.now().millisecondsSinceEpoch}',
                        name: nameController.text.trim(),
                        creatorId: user.uid,
                        memberIds: memberIds,
                        memberNames: memberNames,
                        createdAt: DateTime.now(),
                        updatedAt: DateTime.now(),
                      );

                      try {
                        await _groupService.createGroup(group);
                        await _loadGroups();
                        if (mounted) {
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Group created!')),
                          );
                        }
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Failed to create group: $e')),
                          );
                        }
                      }
                    },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteGroup(FriendGroup group) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Group'),
        content: Text('Are you sure you want to delete "${group.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _groupService.deleteGroup(group.id);
        await _loadGroups();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Group deleted')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to delete group: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Groups'),
        actions: [
          IconButton(
            icon: const Icon(Icons.group_add),
            onPressed: _showCreateGroupDialog,
            tooltip: 'Create Group',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _groups.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.group,
                        size: 64,
                        color: theme.colorScheme.primary.withValues(alpha: 0.3),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No Groups Yet',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Create a group to invite friends to games',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: _showCreateGroupDialog,
                        icon: const Icon(Icons.group_add),
                        label: const Text('Create Group'),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _groups.length,
                  itemBuilder: (context, index) {
                    final group = _groups[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),
                          child: Icon(
                            Icons.group,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        title: Text(
                          group.name,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text('${group.memberIds.length} members'),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          color: Colors.red,
                          onPressed: () => _deleteGroup(group),
                        ),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => GroupDetailPage(group: group),
                            ),
                          ).then((_) => _loadGroups());
                        },
                      ),
                    );
                  },
                ),
    );
  }
}

class GroupDetailPage extends StatefulWidget {
  final FriendGroup group;

  const GroupDetailPage({super.key, required this.group});

  @override
  State<GroupDetailPage> createState() => _GroupDetailPageState();
}

class _GroupDetailPageState extends State<GroupDetailPage> {
  late FriendGroup _group;
  final GroupService _groupService = GroupService();
  final UserService _userService = UserService();
  final AuthService _authService = AuthService();
  List<AppUser> _members = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _group = widget.group;
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    final members = await _userService.getFriends(_group.memberIds);
    setState(() {
      _members = members;
      _isLoading = false;
    });
  }

  Future<void> _removeMember(AppUser member) async {
    try {
      await _groupService.removeMemberFromGroup(_group.id, member.id, member.displayName);
      final updatedGroup = await _groupService.getGroup(_group.id);
      if (updatedGroup != null) {
        setState(() => _group = updatedGroup);
        await _loadMembers();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${member.displayName} removed from group')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to remove member: $e')),
        );
      }
    }
  }

  // Group notifications are always sent to other members when someone checks in.
  // No per-group toggle is needed; simplified UI below shows only member management.

  Future<void> _showAddMembersDialog() async {
    final current = _authService.currentUser;
    if (current == null) return;
    final appUser = await _userService.getUser(current.uid);
    if (appUser == null) return;

    // Candidates: user's friends not already in the group
    final candidates = await _userService.getFriends(appUser.friendIds);
    final memberIdSet = _group.memberIds.toSet();
    final available = candidates.where((u) => !memberIdSet.contains(u.id)).toList();

    if (available.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No friends to add.')),
      );
      return;
    }

    final selected = <String, String>{};

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add Members'),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ...available.map((u) => CheckboxListTile(
                        value: selected.containsKey(u.id),
                        onChanged: (v) {
                          setDialogState(() {
                            if (v == true) {
                              selected[u.id] = u.displayName;
                            } else {
                              selected.remove(u.id);
                            }
                          });
                        },
                        title: Text(u.displayName),
                        contentPadding: EdgeInsets.zero,
                      )),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: selected.isEmpty
                  ? null
                  : () async {
                      try {
                        // Add each selected member
                        for (final entry in selected.entries) {
                          await _groupService.addMemberToGroup(_group.id, entry.key, entry.value);
                        }
                        final updated = await _groupService.getGroup(_group.id);
                        if (updated != null) {
                          setState(() => _group = updated);
                        }
                        await _loadMembers();
                        if (mounted) {
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Added ${selected.length} member(s)')),
                          );
                        }
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Failed to add members: $e')),
                          );
                        }
                      }
                    },
              child: const Text('Add'),
            )
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_group.name),
        actions: [
          IconButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => GroupChatPage(group: _group),
                ),
              );
            },
            icon: const Icon(Icons.chat_bubble_outline),
            tooltip: 'Open Chat',
          ),
          IconButton(
            onPressed: _showAddMembersDialog,
            icon: const Icon(Icons.person_add),
            tooltip: 'Add Members',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ..._members.map((member) => Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),
                          child: member.photoUrl != null
                              ? ClipOval(
                                  child: Image.network(
                                    member.photoUrl!,
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
                        title: Text(member.displayName),
                        subtitle: Text(member.skillLevel),
                        trailing: IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          color: Colors.red,
                          onPressed: () => _removeMember(member),
                        ),
                      ),
                    )),
              ],
            ),
    );
  }
}
