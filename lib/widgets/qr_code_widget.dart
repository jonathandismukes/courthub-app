import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

class QRCodeWidget extends StatelessWidget {
  final String data;
  final double size;
  final Color? eyeColor;
  final Color? dataModuleColor;

  const QRCodeWidget({
    super.key,
    required this.data,
    this.size = 220,
    this.eyeColor,
    this.dataModuleColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: QrImageView(
        data: data,
        size: size,
        backgroundColor: Colors.white,
        eyeStyle: QrEyeStyle(
          eyeShape: QrEyeShape.square,
          color: eyeColor ?? theme.colorScheme.primary,
        ),
        dataModuleStyle: QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: dataModuleColor ?? theme.colorScheme.onSurface,
        ),
      ),
    );
  }
}
