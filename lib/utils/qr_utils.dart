import 'package:flutter/foundation.dart';

enum QrActionType { invite, checkin, unknown }

class QrAction {
  final QrActionType type;
  final Map<String, String> params;
  QrAction(this.type, this.params);
}

// Encode: courthub://invite?gameId=...  OR  courthub://checkin?gameId=...  OR  courthub://checkin?parkId=...
class QrUtils {
  static const String scheme = 'courthub';

  static String buildGameInvitePayload(String gameId) {
    return '$scheme://invite?gameId=$gameId';
  }

  static String buildGameCheckInPayload(String gameId) {
    return '$scheme://checkin?gameId=$gameId';
  }

  static String buildParkCheckInPayload(String parkId) {
    return '$scheme://checkin?parkId=$parkId';
  }

  // New: per-court check-in payload, optionally auto-join the queue
  static String buildCourtCheckInPayload({
    required String parkId,
    required String courtId,
    bool autoQueue = true,
  }) {
    final queueParam = autoQueue ? '&queue=1' : '';
    return '$scheme://checkin?parkId=$parkId&courtId=$courtId$queueParam';
  }

  static QrAction parse(String raw) {
    try {
      final uri = Uri.tryParse(raw);
      if (uri == null) return QrAction(QrActionType.unknown, {});
      if (uri.scheme != scheme) return QrAction(QrActionType.unknown, {});

      if (uri.host == 'invite') {
        final gameId = uri.queryParameters['gameId'];
        if (gameId != null && gameId.isNotEmpty) {
          return QrAction(QrActionType.invite, {'gameId': gameId});
        }
      }

      if (uri.host == 'checkin') {
        final params = <String, String>{};
        if ((uri.queryParameters['gameId'] ?? '').isNotEmpty) {
          params['gameId'] = uri.queryParameters['gameId']!;
        }
        if ((uri.queryParameters['parkId'] ?? '').isNotEmpty) {
          params['parkId'] = uri.queryParameters['parkId']!;
        }
        if ((uri.queryParameters['courtId'] ?? '').isNotEmpty) {
          params['courtId'] = uri.queryParameters['courtId']!;
        }
        // queue=1 indicates auto join queue after check-in
        final queueRaw = uri.queryParameters['queue'] ?? uri.queryParameters['autoQueue'];
        if (queueRaw != null && queueRaw.isNotEmpty) {
          params['queue'] = queueRaw;
        }
        if (params.isNotEmpty) {
          return QrAction(QrActionType.checkin, params);
        }
      }
    } catch (e) {
      debugPrint('QR parse error: $e');
    }
    return QrAction(QrActionType.unknown, {});
  }
}
