import 'package:flutter/material.dart';
import 'package:hoopsight/models/park_model.dart';
import 'package:hoopsight/services/auth_service.dart';
import 'package:hoopsight/services/park_service.dart';

class AdminPendingParksPage extends StatefulWidget {
  const AdminPendingParksPage({super.key});

  @override
  State<AdminPendingParksPage> createState() => _AdminPendingParksPageState();
}

class _AdminPendingParksPageState extends State<AdminPendingParksPage> {
  final ParkService _parkService = ParkService();
  final AuthService _authService = AuthService();
  bool _isLoading = true;
  List<Park> _pending = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final items = await _parkService.getPendingParks();
    if (!mounted) return;
    setState(() {
      _pending = items;
      _isLoading = false;
    });
  }

  Future<void> _approve(String parkId) async {
    final uid = _authService.currentUser?.uid;
    if (uid == null) return;
    await _parkService.approvePark(parkId, uid);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Park approved')),
    );
  }

  Future<void> _reject(String parkId, String name) async {
    final controller = TextEditingController();
    final theme = Theme.of(context);
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject submission'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Reason (optional)',
            hintText: 'Explain why this park cannot be approved',
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: theme.textTheme.labelLarge),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    if (reason == null) return; // cancelled

    final uid = _authService.currentUser?.uid;
    if (uid == null) return;

    await _parkService.denyPark(parkId, uid, reason);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Rejected "$name"')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pending Park Approvals'),
        actions: const [],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _pending.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.park_outlined, size: 64, color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
                      const SizedBox(height: 12),
                      Text('No submissions awaiting approval', style: theme.textTheme.titleMedium),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _pending.length,
                  itemBuilder: (context, index) {
                    final park = _pending[index];
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(park.name, style: theme.textTheme.titleMedium),
                            const SizedBox(height: 4),
                            Text('${park.city}, ${park.state}', style: theme.textTheme.bodySmall),
                            if (park.createdByName != null) ...[
                              const SizedBox(height: 6),
                              Text('Submitted by: ${park.createdByName}', style: theme.textTheme.bodySmall),
                            ],
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                ElevatedButton.icon(
                                  onPressed: () => _approve(park.id),
                                  icon: const Icon(Icons.check),
                                  label: const Text('Approve'),
                                ),
                                const SizedBox(width: 12),
                                TextButton.icon(
                                  onPressed: () => _reject(park.id, park.name),
                                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                                  label: const Text('Reject'),
                                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                                ),
                              ],
                            )
                          ],
                        ),
                      ),
                    );
                  },
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                ),
    );
  }
}
