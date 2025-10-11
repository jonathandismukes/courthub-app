import 'package:flutter/material.dart';
import 'package:hoopsight/models/user_model.dart';
import 'package:hoopsight/services/auth_service.dart';
import 'package:hoopsight/services/user_service.dart';
import 'package:hoopsight/services/notification_service.dart';
import 'package:hoopsight/screens/landing_page.dart';
import 'package:hoopsight/screens/edit_profile_page.dart';
import 'package:hoopsight/screens/my_games_page.dart';
import 'package:hoopsight/screens/favorites_page.dart';
import 'package:hoopsight/screens/friends_page.dart';
import 'package:hoopsight/screens/groups_page.dart';
import 'package:hoopsight/screens/privacy_policy_page.dart';
import 'package:hoopsight/screens/support_page.dart';
import 'package:hoopsight/screens/admin_pending_parks_page.dart';
import 'package:url_launcher/url_launcher.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final AuthService _authService = AuthService();
  final UserService _userService = UserService();
  final NotificationService _notificationService = NotificationService();
  AppUser? _currentUser;
  bool _isLoading = true;
  bool _notificationsEnabled = false;

  @override
  void initState() {
    super.initState();
    _loadUserProfile();
  }

  Future<void> _loadUserProfile() async {
    final firebaseUser = _authService.currentUser;
    if (firebaseUser != null) {
      final user = await _userService.getUser(firebaseUser.uid);
      final notifEnabled = await _notificationService.areNotificationsEnabled();
      setState(() {
        _currentUser = user;
        _notificationsEnabled = notifEnabled;
        _isLoading = false;
      });
    } else {
      setState(() => _isLoading = false);
    }
  }



  Future<void> _handleNotificationToggle(bool newValue) async {
    if (newValue) {
      // User wants to enable notifications
      final granted = await _notificationService.requestNotificationPermission();
      if (granted) {
        // Save FCM token
        final firebaseUser = _authService.currentUser;
        if (firebaseUser != null) {
          final success = await _notificationService.ensureAndSaveFCMToken(firebaseUser.uid);
          setState(() => _notificationsEnabled = success);
          if (success && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('🔔 Notifications enabled!'),
                backgroundColor: Colors.green,
              ),
            );
          }
        }
      } else {
        // Permission denied - show dialog to open settings
        if (mounted) {
          _showOpenSettingsDialog();
        }
      }
    } else {
      // User wants to disable notifications
      final firebaseUser = _authService.currentUser;
      if (firebaseUser != null) {
        await _notificationService.removeFCMToken(firebaseUser.uid);
        setState(() => _notificationsEnabled = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('🔕 Notifications disabled'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    }
  }

  void _showOpenSettingsDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Notification Permission Required'),
        content: const Text(
          'Notifications are blocked. To enable them, please open your device settings and allow notifications for this app.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              // Open app settings (platform-specific)
              final Uri settingsUri = Uri.parse('app-settings:');
              if (await canLaunchUrl(settingsUri)) {
                await launchUrl(settingsUri);
              }
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Logout'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _authService.signOut();
      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const LandingPage()),
          (route) => false,
        );
      }
    }
  }

  Future<void> _handleDeleteAccount() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Account'),
        content: const Text(
          'This will permanently delete your account and data. This action cannot be undone. Are you sure you want to continue?'
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await _authService.deleteAccount();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Your account has been deleted.'),
            backgroundColor: Colors.red,
          ),
        );
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const LandingPage()),
          (route) => false,
        );
      } catch (e) {
        if (!mounted) return;
        final message = e.toString().contains('requires-recent-login')
            ? 'Please log in again, then try deleting your account.'
            : 'Failed to delete account. Please try again.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _handleReportProblem() async {
    // Open email to support with a simple subject and a short, privacy-safe opening line.
    final subject = Uri.encodeComponent('Report a problem');
    final body = Uri.encodeComponent("Hi Support, I'm experiencing a problem with the app. [Please attach screenshots if possible]");
    final uri = Uri.parse(
        'mailto:silverstreak622000@yahoo.com?subject=$subject&body=$body');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open mail app. Please email support.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_currentUser == null) {
      return Scaffold(
        body: SafeArea(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  theme.colorScheme.primary.withValues(alpha: 0.1),
                  theme.colorScheme.secondary.withValues(alpha: 0.05),
                ],
              ),
            ),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.person_outline,
                        size: 60,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Browsing as Guest',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Sign in to unlock all features:',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: Colors.grey[600],
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    _GuestFeatureItem(icon: Icons.check_circle, text: 'Check in to courts'),
                    _GuestFeatureItem(icon: Icons.favorite, text: 'Save favorite parks'),
                    _GuestFeatureItem(icon: Icons.people, text: 'Connect with friends'),
                    _GuestFeatureItem(icon: Icons.sports_basketball, text: 'Create and join games'),
                    _GuestFeatureItem(icon: Icons.notifications, text: 'Get activity notifications'),
                    const SizedBox(height: 32),
                    ElevatedButton(
                      onPressed: () {
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(builder: (_) => const LandingPage()),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 18),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                        elevation: 4,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.login),
                          const SizedBox(width: 8),
                          Text(
                            'Sign In',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      theme.colorScheme.primary,
                      theme.colorScheme.secondary,
                    ],
                  ),
                ),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        // Top-right overflow menu (less prominent destructive action)
                        Row(
                          children: [
                            const Spacer(),
                            PopupMenuButton<String>(
                              tooltip: 'More',
                              onSelected: (value) {
                                if (value == 'delete') {
                                  _handleDeleteAccount();
                                } else if (value == 'support') {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (_) => const SupportPage()),
                                  );
                                }
                              },
                              itemBuilder: (context) => [
                                PopupMenuItem<String>(
                                  value: 'support',
                                  child: Row(
                                    children: const [
                                      Icon(Icons.help_outline, color: Colors.black87, size: 18),
                                      SizedBox(width: 8),
                                      Text('Support / FAQ'),
                                    ],
                                  ),
                                ),
                                PopupMenuItem<String>(
                                  value: 'delete',
                                  child: Row(
                                    children: const [
                                      Icon(Icons.delete_outline, color: Colors.red, size: 18),
                                      SizedBox(width: 8),
                                      Text(
                                        'Delete account',
                                        style: TextStyle(color: Colors.red),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                              icon: Icon(
                                Icons.more_vert,
                                color: Colors.white.withValues(alpha: 0.9),
                              ),
                            ),
                          ],
                        ),
                      CircleAvatar(
                        radius: 50,
                        backgroundColor: Colors.white,
                        child: _currentUser!.photoUrl != null
                            ? ClipOval(
                                child: Image.network(
                                  _currentUser!.photoUrl!,
                                  width: 100,
                                  height: 100,
                                  fit: BoxFit.cover,
                                ),
                              )
                            : Icon(
                                Icons.person,
                                size: 50,
                                color: theme.colorScheme.primary,
                              ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            _currentUser!.displayName,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (_currentUser!.isAdmin) ...[
                            const SizedBox(width: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.red,
                                borderRadius: BorderRadius.circular(6),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.red.withValues(alpha: 0.4),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: const Text(
                                'ADMIN',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _currentUser!.email,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                      ),
                      if (_currentUser!.bio != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _currentUser!.bio!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.white.withValues(alpha: 0.8),
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      const SizedBox(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _StatCard(
                            label: 'Games',
                            value: '${_currentUser!.gamesPlayed}',
                          ),
                          _StatCard(
                            label: 'Favorites',
                            value: '${_currentUser!.favoriteParkIds.length}',
                          ),
                          _StatCard(
                            label: 'Friends',
                            value: '${_currentUser!.friendIds.length}',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              if (_currentUser != null && _currentUser!.isAdmin)
                _MenuItem(
                  icon: Icons.verified_user,
                  title: 'Pending Park Approvals',
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const AdminPendingParksPage()),
                    );
                  },
                ),
              _MenuItem(
                icon: Icons.edit,
                title: 'Edit Profile',
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const EditProfilePage()),
                  );
                  _loadUserProfile();
                },
              ),
              _MenuItem(
                icon: Icons.sports_basketball,
                title: 'My Games',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const MyGamesPage()),
                  );
                },
              ),
              _MenuItem(
                icon: Icons.favorite,
                title: 'Favorite Parks',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const FavoritesPage()),
                  );
                },
              ),
              _MenuItem(
                icon: Icons.people,
                title: 'Friends',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const FriendsPage()),
                  );
                },
              ),
              _MenuItem(
                icon: Icons.group,
                title: 'My Groups',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const GroupsPage()),
                  );
                },
              ),
              _NotificationToggle(
                enabled: _notificationsEnabled,
                onToggle: _handleNotificationToggle,
              ),
              _MenuItem(
                icon: Icons.bug_report,
                title: 'Report a problem',
                onTap: _handleReportProblem,
              ),
              _MenuItem(
                icon: Icons.privacy_tip_outlined,
                title: 'Privacy Policy',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const PrivacyPolicyPage()),
                  );
                },
              ),
              _MenuItem(
                icon: Icons.logout,
                title: 'Logout',
                onTap: _handleLogout,
                isDestructive: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GuestFeatureItem extends StatelessWidget {
  final IconData icon;
  final String text;

  const _GuestFeatureItem({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.primary, size: 24),
          const SizedBox(width: 12),
          Text(text, style: theme.textTheme.bodyLarge),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;

  const _StatCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.8),
            fontSize: 14,
          ),
        ),
      ],
    );
  }
}

class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool isDestructive;

  const _MenuItem({
    required this.icon,
    required this.title,
    required this.onTap,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isDestructive ? theme.colorScheme.error : theme.colorScheme.onSurface;

    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(
        title,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w500,
        ),
      ),
      trailing: Icon(Icons.chevron_right, color: color.withValues(alpha: 0.5)),
      onTap: onTap,
    );
  }
}

class _NotificationToggle extends StatelessWidget {
  final bool enabled;
  final Function(bool) onToggle;

  const _NotificationToggle({
    required this.enabled,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      leading: Icon(
        enabled ? Icons.notifications_active : Icons.notifications_off,
        color: theme.colorScheme.onSurface,
      ),
      title: Text(
        'Push Notifications',
        style: TextStyle(
          color: theme.colorScheme.onSurface,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        enabled ? 'Enabled' : 'Disabled',
        style: TextStyle(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          fontSize: 12,
        ),
      ),
      trailing: Switch(
        value: enabled,
        onChanged: onToggle,
        activeColor: theme.colorScheme.primary,
      ),
    );
  }
}
