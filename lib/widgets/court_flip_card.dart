import 'dart:math';
import 'package:flutter/material.dart';
import 'package:hoopsight/models/park_model.dart';

class CourtFlipCard extends StatefulWidget {
  final Court court;
  final ThemeData theme;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final Function(bool) onQueueAction;
  final Function(String, String) onMarkAsPlaying;
  final Function(String, String) onStillWaiting;
  final bool isInQueue;
  final bool isUserLoggedIn;
  final VoidCallback? onShowCourtQr;

  const CourtFlipCard({
    super.key,
    required this.court,
    required this.theme,
    required this.onEdit,
    required this.onRemove,
    required this.onQueueAction,
    required this.onMarkAsPlaying,
    required this.onStillWaiting,
    required this.isInQueue,
    required this.isUserLoggedIn,
    this.onShowCourtQr,
  });

  @override
  State<CourtFlipCard> createState() => _CourtFlipCardState();
}

class _CourtFlipCardState extends State<CourtFlipCard> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  bool _isFlipped = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _animation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _flip() {
    if (_isFlipped) {
      _controller.reverse();
    } else {
      _controller.forward();
    }
    setState(() => _isFlipped = !_isFlipped);
  }

  String _getTimeAgo(DateTime dateTime) {
    final difference = DateTime.now().difference(dateTime);
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inMinutes < 60) return '${difference.inMinutes}m ago';
    if (difference.inHours < 24) return '${difference.inHours}h ago';
    return '${difference.inDays}d ago';
  }

  String _getTimeRemaining(Duration duration) {
    // Timeout window is 60 minutes
    final remaining = const Duration(minutes: 60) - duration;
    if (remaining.isNegative) return 'Expired';
    return '${remaining.inMinutes}m ${remaining.inSeconds % 60}s';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.court.gotNextQueue.isNotEmpty ? _flip : null,
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, child) {
          final angle = _animation.value * pi;
          final isBack = angle > pi / 2;
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.001)
              ..rotateY(angle),
            child: isBack
                ? Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()..rotateY(pi),
                    child: _buildBackCard(),
                  )
                : _buildFrontCard(),
          );
        },
      ),
    );
  }

  Widget _buildFrontCard() {
    final isFull = widget.court.playerCount >= widget.court.maxPlayers;
    final isEmpty = widget.court.playerCount == 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: widget.theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: widget.theme.colorScheme.onSurface.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: widget.theme.colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    widget.court.sportType == SportType.basketball
                        ? const Text('🏀', style: TextStyle(fontSize: 14))
                        : (widget.court.sportType == SportType.pickleballSingles ||
                                widget.court.sportType == SportType.pickleballDoubles)
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(3),
                                child: Image.asset('assets/images/p.jpeg', width: 14, height: 14, fit: BoxFit.contain),
                              )
                            : const Text('🎾', style: TextStyle(fontSize: 14)),
                    const SizedBox(width: 6),
                    Text(
                      widget.court.displayName,
                      style: widget.theme.textTheme.labelLarge?.copyWith(
                          color: widget.theme.colorScheme.primary, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _buildConditionBadge(widget.court.condition),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isFull
                      ? widget.theme.colorScheme.error.withValues(alpha: 0.1)
                      : isEmpty
                          ? widget.theme.colorScheme.onSurface.withValues(alpha: 0.05)
                          : widget.theme.colorScheme.tertiary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  isFull ? 'Full' : isEmpty ? 'Empty' : 'Available',
                  style: widget.theme.textTheme.labelSmall?.copyWith(
                    color: isFull
                        ? widget.theme.colorScheme.error
                        : isEmpty
                            ? widget.theme.colorScheme.onSurface.withValues(alpha: 0.5)
                            : widget.theme.colorScheme.tertiary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                color: widget.theme.colorScheme.primary,
                onPressed: widget.onEdit,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 8),
              if (widget.onShowCourtQr != null) ...[
                IconButton(
                  icon: const Icon(Icons.qr_code_2, size: 22),
                  color: widget.theme.colorScheme.primary,
                  onPressed: widget.onShowCourtQr,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 8),
              ],
              
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                color: widget.theme.colorScheme.error,
                onPressed: widget.onRemove,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Players',
                        style: widget.theme.textTheme.labelMedium
                            ?.copyWith(color: widget.theme.colorScheme.onSurface.withValues(alpha: 0.6))),
                    Row(
                      children: [
                        Text('${widget.court.playerCount}',
                            style: widget.theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                        Text(' / ${widget.court.maxPlayers}',
                            style: widget.theme.textTheme.titleMedium
                                ?.copyWith(color: widget.theme.colorScheme.onSurface.withValues(alpha: 0.4))),
                      ],
                    ),
                  ],
                ),
              ),
              if (widget.court.hasLighting) Icon(Icons.lightbulb, color: Colors.amber, size: 20),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Updated ${_getTimeAgo(widget.court.lastUpdated)}',
            style: widget.theme.textTheme.bodySmall
                ?.copyWith(color: widget.theme.colorScheme.onSurface.withValues(alpha: 0.4)),
          ),
          if (widget.court.gotNextQueue.isNotEmpty || widget.isUserLoggedIn) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: widget.theme.colorScheme.secondary.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: widget.theme.colorScheme.secondary.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  Icon(Icons.queue, size: 18, color: widget.theme.colorScheme.secondary),
                  const SizedBox(width: 6),
                  Text(
                    widget.court.gotNextQueue.isEmpty
                        ? 'No one waiting'
                        : '${widget.court.gotNextQueue.length} waiting',
                    style: widget.theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold, color: widget.theme.colorScheme.secondary),
                  ),
                  const Spacer(),
                  if (widget.isUserLoggedIn)
                    TextButton(
                      onPressed: () => widget.onQueueAction(widget.isInQueue),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        widget.isInQueue ? 'Leave Queue' : 'Join Queue',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                  if (widget.court.gotNextQueue.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.flip, size: 18),
                      onPressed: _flip,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: 'View Queue',
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBackCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: widget.theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: widget.theme.colorScheme.secondary.withValues(alpha: 0.3), width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.queue, size: 20, color: widget.theme.colorScheme.secondary),
              const SizedBox(width: 8),
              Text(
                'Queue for ${widget.court.displayName}',
                style: widget.theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold, color: widget.theme.colorScheme.secondary),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.flip, size: 18),
                onPressed: _flip,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (widget.court.gotNextQueue.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'No one waiting yet',
                  style: widget.theme.textTheme.bodyMedium
                      ?.copyWith(color: widget.theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                ),
              ),
            )
          else
            ...widget.court.gotNextQueue.asMap().entries.map((entry) {
              final index = entry.key;
              final player = entry.value;
              final isExpired = player.isExpired;
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isExpired
                        ? widget.theme.colorScheme.error.withValues(alpha: 0.1)
                        : widget.theme.colorScheme.secondary.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isExpired
                          ? widget.theme.colorScheme.error.withValues(alpha: 0.3)
                          : widget.theme.colorScheme.secondary.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: isExpired
                                  ? widget.theme.colorScheme.error
                                  : widget.theme.colorScheme.secondary,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '${index + 1}',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  player.userName,
                                  style: widget.theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                                ),
                                Text(
                                  isExpired ? 'Expired' : 'Time remaining: ${_getTimeRemaining(player.timeInQueue)}',
                                  style: widget.theme.textTheme.bodySmall?.copyWith(
                                    color: isExpired
                                        ? widget.theme.colorScheme.error
                                        : widget.theme.colorScheme.onSurface.withValues(alpha: 0.6),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (!isExpired)
                            OutlinedButton.icon(
                              onPressed: () => widget.onStillWaiting(player.userId, player.userName),
                              icon: const Icon(Icons.refresh, size: 16),
                              label: const Text('Still Waiting', style: TextStyle(fontSize: 11)),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                side: BorderSide(color: widget.theme.colorScheme.secondary),
                              ),
                            ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: Icon(
                              Icons.sports_basketball,
                              size: 18,
                              color: widget.theme.colorScheme.tertiary,
                            ),
                            onPressed: () => widget.onMarkAsPlaying(player.userId, player.userName),
                            style: IconButton.styleFrom(
                              backgroundColor: widget.theme.colorScheme.tertiary.withValues(alpha: 0.1),
                              padding: const EdgeInsets.all(8),
                            ),
                            tooltip: 'Mark as Playing',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildConditionBadge(CourtCondition condition) {
    final conditionMap = {
      CourtCondition.excellent: {'label': 'Excellent', 'color': Colors.green},
      CourtCondition.good: {'label': 'Good', 'color': Colors.blue},
      CourtCondition.fair: {'label': 'Fair', 'color': Colors.orange},
      CourtCondition.poor: {'label': 'Poor', 'color': Colors.red},
      CourtCondition.maintenance: {'label': 'Maintenance', 'color': Colors.grey},
    };

    final data = conditionMap[condition]!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: (data['color'] as Color).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        data['label'] as String,
        style: widget.theme.textTheme.labelSmall?.copyWith(
          color: data['color'] as Color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
