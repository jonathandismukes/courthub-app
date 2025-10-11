import 'package:flutter/material.dart';

class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lastUpdated = DateTime.now();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Privacy Policy'),
      ),
      body: SizedBox.expand(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                theme.colorScheme.primary.withValues(alpha: 0.06),
                theme.colorScheme.secondary.withValues(alpha: 0.04),
              ],
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
              Text(
                'CourtHub Privacy Policy',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Last updated: ${lastUpdated.month}/${lastUpdated.day}/${lastUpdated.year}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 24),
              _Section(
                title: 'Overview',
                body:
                    'CourtHub helps you find nearby courts and see how many people are playing. We only collect the information we need to provide these features and improve the app.',
              ),
              _Section(
                title: 'What we collect',
                body:
                    '• Account info: email, display name, optional profile photo and phone number.\n'
                    '• Location: only when you grant permission and while you use location features (e.g., Map tab).\n'
                    '• App activity: check-ins, favorites, and basic usage analytics (non-identifying).',
              ),
              _Section(
                title: 'How we use your data',
                body:
                    '• Show courts near you and distance from your current location.\n'
                    '• Power social features like friends, groups, and game invites.\n'
                    '• Send optional notifications you enable in Settings.',
              ),
              _Section(
                title: 'Sharing',
                body:
                    'We do not sell your data. We share data only to operate the app (e.g., Firebase for authentication, database, and notifications) and as required by law.',
              ),
              _Section(
                title: 'Your choices',
                body:
                    '• You can disable notifications anytime in Profile > Push Notifications.\n'
                    '• You can revoke location permission in your device settings.\n'
                    '• You can delete your account in Profile > ⋯ > Delete account. When you do, we delete your account and all data we collected with your account (including profile, check-ins, reviews, games you created, group messages, invites, friend connections, reports, tokens, and profile photo).',
              ),
              _Section(
                title: 'Data retention',
                body:
                    'We retain your account data while your account is active. When you delete your account in the app, we immediately delete your personal data and content. Some aggregate metrics may be recomputed, but your identifiers are removed.',
              ),
              _Section(
                title: 'Contact',
                body:
                    'For privacy questions, email: silverstreak622000@yahoo.com. For account deletion, you can delete your account in the app (Profile > ⋯ > Delete account).',
              ),
              const SizedBox(height: 32),
              Text(
                'This policy may be updated as we add features. We will post updates here.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String body;
  const _Section({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
        ],
      ),
    );
  }
}
