import 'package:flutter/material.dart';
import 'package:hoopsight/models/group_model.dart';
import 'package:hoopsight/models/group_message_model.dart';
import 'package:hoopsight/models/user_model.dart';
import 'package:hoopsight/services/auth_service.dart';
import 'package:hoopsight/services/group_chat_service.dart';
import 'package:hoopsight/services/group_service.dart';
import 'package:hoopsight/services/user_service.dart';
import 'package:hoopsight/utils/moderation.dart';

class GroupChatPage extends StatefulWidget {
  final FriendGroup group;
  const GroupChatPage({super.key, required this.group});

  @override
  State<GroupChatPage> createState() => _GroupChatPageState();
}

class _GroupChatPageState extends State<GroupChatPage> {
  final _chatService = GroupChatService();
  final _groupService = GroupService();
  final _userService = UserService();
  final _authService = AuthService();
  final _controller = TextEditingController();
  AppUser? _me;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _loadMe();
  }

  Future<void> _loadMe() async {
    final user = _authService.currentUser;
    if (user == null) return;
    final me = await _userService.getUser(user.uid);
    setState(() => _me = me);
  }

  Future<void> _send() async {
    if (_sending) return;
    final raw = _controller.text.trim();
    if (raw.isEmpty) return;
    final current = _authService.currentUser;
    if (current == null) return;

    setState(() => _sending = true);
    try {
      // Validate membership
      final group = await _groupService.getGroup(widget.group.id);
      if (group == null || !group.memberIds.contains(current.uid)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('You are not a member of this group.')),
          );
        }
        return;
      }

      // Client-side moderation
      final result = Moderation.process(raw);
      if (result.looksLikeSpam) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Message blocked as spam.')),
          );
        }
        return;
      }

      // Block filtering: don't send if any member has blocked me? We'll let rules handle visibility.
      final id = '${DateTime.now().millisecondsSinceEpoch}_${current.uid}';
      final msg = GroupMessage(
        id: id,
        groupId: widget.group.id,
        senderId: current.uid,
        senderName: _me?.displayName ?? 'Unknown',
        senderPhotoUrl: _me?.photoUrl,
        text: result.cleanedText,
        createdAt: DateTime.now(),
        containsProfanity: result.containsProfanity,
        looksLikeSpam: false,
        flaggedKeywords: result.flaggedKeywords,
      );

      await _chatService.sendMessage(widget.group.id, msg);
      _controller.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final meId = _authService.currentUser?.uid;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('${widget.group.name} Chat')),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<GroupMessage>>(
              stream: _chatService.watchMessages(widget.group.id, limit: 200),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final messages = (snap.data ?? [])
                    .where((m) => !_isFromBlocked(m))
                    .toList();
                // They come descending; reverse for chat order
                messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));

                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final m = messages[index];
                    final isMe = m.senderId == meId;
                    final bubbleColor = isMe
                        ? theme.colorScheme.primary.withValues(alpha: 0.12)
                        : theme.colorScheme.surfaceContainerHighest;
                    final textColor = theme.colorScheme.onSurface;

                    return Align(
                      alignment:
                          isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(
                            vertical: 8, horizontal: 12),
                        constraints: const BoxConstraints(maxWidth: 320),
                        decoration: BoxDecoration(
                          color: bubbleColor,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  m.senderName,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.8),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _formatTime(m.createdAt),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.6),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              m.text,
                              style: TextStyle(color: textColor),
                            ),
                            if (m.containsProfanity || m.flaggedKeywords.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.shield,
                                        size: 14,
                                        color: theme.colorScheme.tertiary),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Moderated',
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: theme.colorScheme.tertiary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12).copyWith(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: 'Message group...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _sending ? null : _send,
                    icon: _sending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                    color: Theme.of(context).colorScheme.primary,
                  )
                ],
              ),
            ),
          )
        ],
      ),
    );
  }

  bool _isFromBlocked(GroupMessage m) {
    final me = _me;
    if (me == null) return false;
    return me.blockedUserIds.contains(m.senderId);
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    if (now.difference(dt).inDays == 0) {
      final hh = dt.hour.toString().padLeft(2, '0');
      final mm = dt.minute.toString().padLeft(2, '0');
      return '$hh:$mm';
    }
    return '${dt.month}/${dt.day}';
  }
}
