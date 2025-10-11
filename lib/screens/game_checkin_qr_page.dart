import 'package:flutter/material.dart';
import 'package:hoopsight/utils/qr_utils.dart';
import 'package:hoopsight/widgets/qr_code_widget.dart';

class GameCheckInQrPage extends StatelessWidget {
  final String gameId;

  const GameCheckInQrPage({super.key, required this.gameId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = QrUtils.buildGameCheckInPayload(gameId);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Game Check-in QR'),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  'Have players scan this to check in',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                // Bounded size to avoid intrinsic sizing issues on web
                QRCodeWidget(data: data, size: 280),
                const SizedBox(height: 16),
                Text(
                  'This code links directly to this game and safely checks players in.',
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close),
                    label: const Text('Close'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
