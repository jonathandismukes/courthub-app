import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class SupportPage extends StatelessWidget {
  const SupportPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Support & FAQ'),
      ),
      body: SizedBox.expand(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                theme.colorScheme.primary.withValues(alpha: 0.04),
                theme.colorScheme.secondary.withValues(alpha: 0.03),
              ],
            ),
          ),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
          _SectionHeader(title: 'Getting Started', icon: Icons.flag),
          const SizedBox(height: 8),
          _FaqItem(
            question: 'Do I need an account to use CourtHub?',
            answer:
                'You can browse as a guest with limited features (nearby and search). To check in, save favorites, connect with friends, and get notifications, create a free account for full access.',
          ),
          _FaqItem(
            question: 'Is CourtHub free?',
            answer:
                'Yes, the core features are free to use. We may offer optional paid upgrades in the future to enhance your experience.',
          ),
          const SizedBox(height: 16),
          _SectionHeader(title: 'Features & Permissions', icon: Icons.settings),
          const SizedBox(height: 8),
          _FaqItem(
            question: 'What location permissions does the app use?',
            answer:
                'We request “While In Use” location permission only. We do not track your location in the background.',
          ),
          _FaqItem(
            question: 'How do push notifications work?',
            answer:
                'Notifications are optional. The app will only ask for notification permission if you enable notifications from your Profile settings.',
          ),
          _FaqItem(
            question: 'How do I check in to a court?',
            answer:
                'Open a park, select a court, then use the check-in controls to update player counts and let others know the current activity.',
          ),
          const SizedBox(height: 16),
          _SectionHeader(title: 'Account & Privacy', icon: Icons.lock_outline),
          const SizedBox(height: 8),
          _FaqItem(
            question: 'How do I delete my account?',
            answer:
                'Go to Profile, tap the top-right menu (⋯), choose “Delete Account,” and confirm. This permanently deletes your account and all data we collected with your account (profile, check-ins, reviews, games you created, group messages, invites, friend connections, reports, notification tokens, and profile photo). We also remove you from other users\' friends and groups. This action can’t be undone.',
          ),
          _FaqItem(
            question: 'What happens to my data after deletion?',
            answer:
                'Deletion is immediate. Your personal content and identifiers are removed from our database and storage. Content in shared contexts (e.g., game rosters, groups) is updated to remove your presence. No new processing occurs after deletion.',
          ),
          _FaqItem(
            question: 'How is my data used?',
            answer:
                'We use your data to provide core features like profiles, favorites, groups, and check-ins. See the in-app Privacy Policy for details.',
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.support_agent, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Need more help?',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text('Email us at ', style: theme.textTheme.bodyMedium),
                          TextButton(
                            style: TextButton.styleFrom(padding: EdgeInsets.zero),
                            onPressed: () async {
                              final Uri emailUri = Uri(
                                scheme: 'mailto',
                                path: 'silverstreak622000@yahoo.com',
                              );
                              if (await canLaunchUrl(emailUri)) {
                                await launchUrl(emailUri);
                              }
                            },
                            child: const Text('silverstreak622000@yahoo.com'),
                          ),
                          Text(
                            ' and we\'ll get back to you as soon as possible.',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
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
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final IconData icon;
  const _SectionHeader({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}

class _FaqItem extends StatelessWidget {
  final String question;
  final String answer;
  const _FaqItem({required this.question, required this.answer});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        title: Text(
          question,
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              answer,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
