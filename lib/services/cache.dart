import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A cached JSON value plus the time it was fetched, so offline answers can
/// say how stale they are.
class Cached<T> {
  final T value;
  final DateTime fetchedAt;
  final bool fromCache;

  Cached(this.value, this.fetchedAt, {this.fromCache = false});

  Duration get age => DateTime.now().difference(fetchedAt);
}

class JsonCache {
  static Future<void> put(String key, Map<String, dynamic> value) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      'cache.$key',
      jsonEncode({'at': DateTime.now().toIso8601String(), 'v': value}),
    );
  }

  static Future<Cached<Map<String, dynamic>>?> get(String key) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('cache.$key');
    if (raw == null) return null;
    final d = jsonDecode(raw) as Map<String, dynamic>;
    return Cached(
      d['v'] as Map<String, dynamic>,
      DateTime.parse(d['at'] as String),
      fromCache: true,
    );
  }
}

String describeAge(Duration d) {
  if (d.inMinutes < 2) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} minutes ago';
  if (d.inHours < 24) {
    return '${d.inHours} hour${d.inHours == 1 ? '' : 's'} ago';
  }
  return '${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
}
