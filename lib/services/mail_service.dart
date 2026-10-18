import 'package:enough_mail/enough_mail.dart';

import '../config/settings.dart';
import 'cache.dart';

/// Reads the inbox over IMAP (works with Gmail, Outlook, Yahoo, etc.).
/// Only headers are fetched: sender, subject, date. The last result is
/// cached so "check my email" still answers offline.
class MailService {
  static const _cacheKey = 'mail.summary';

  Future<Cached<Map<String, dynamic>>> checkInbox(
    Settings s, {
    int maxMessages = 5,
  }) async {
    if (!s.hasMail) {
      throw MailException(
        'Your email account is not configured yet. Add it in settings.',
      );
    }
    final client = ImapClient(isLogEnabled: false);
    try {
      await client
          .connectToServer(s.imapHost, s.imapPort, isSecure: true)
          .timeout(const Duration(seconds: 10));
      await client.login(s.mailUser, s.mailPassword);
      await client.selectInbox();
      final search = await client.searchMessages(searchCriteria: 'UNSEEN');
      final ids = search.matchingSequence?.toList() ?? <int>[];
      final latest = ids.length > maxMessages
          ? ids.sublist(ids.length - maxMessages)
          : ids;

      final messages = <Map<String, dynamic>>[];
      if (latest.isNotEmpty) {
        final fetch = await client.fetchMessages(
          MessageSequence.fromIds(latest),
          '(ENVELOPE)',
        );
        for (final m in fetch.messages.reversed) {
          final from = m.from?.isNotEmpty == true ? m.from!.first : null;
          messages.add({
            'from': (from?.personalName?.isNotEmpty ?? false)
                ? from!.personalName
                : from?.email ?? 'unknown sender',
            'subject': m.decodeSubject() ?? '(no subject)',
            'date': m.decodeDate()?.toIso8601String(),
          });
        }
      }
      final result = <String, dynamic>{
        'unread_count': ids.length,
        'latest_unread': messages,
      };
      await JsonCache.put(_cacheKey, result);
      return Cached(result, DateTime.now());
    } on ImapException catch (e) {
      final cached = await JsonCache.get(_cacheKey);
      if (cached != null && !_isAuthError(e)) return cached;
      throw MailException(
        _isAuthError(e)
            ? 'The mail server rejected the login. If you use Gmail, you need an app password.'
            : 'The mail server reported a problem.',
      );
    } catch (_) {
      final cached = await JsonCache.get(_cacheKey);
      if (cached != null) return cached;
      throw MailException('I cannot reach your mail server right now');
    } finally {
      try {
        if (client.isLoggedIn) await client.logout();
        await client.disconnect();
      } catch (_) {}
    }
  }

  bool _isAuthError(ImapException e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('auth') ||
        msg.contains('credentials') ||
        msg.contains('login');
  }
}

class MailException implements Exception {
  final String message;
  MailException(this.message);
  @override
  String toString() => message;
}
