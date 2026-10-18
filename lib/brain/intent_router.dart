/// Offline intent matching for the core commands. These never need the
/// cloud, so "what time is it" answers instantly even without a network.
enum Intent { time, date, weather, email, newConversation, stop, unknown }

class RoutedIntent {
  final Intent intent;
  final String? city;
  const RoutedIntent(this.intent, {this.city});
}

class IntentRouter {
  static final _time = RegExp(
    r"\b(what('?s| is) the time|what time is it|current time|time (is it )?now|tell me the time)\b",
  );
  static final _date = RegExp(
    r"\b(what('?s| is) (the|today'?s) date|what day is (it|today)|today'?s date|what('?s| is) today)\b",
  );
  static final _weather = RegExp(
    r'\b(weather|forecast|temperature|how (hot|cold|warm) is it|is it (going to )?rain(ing)?|umbrella)\b',
  );
  static final _city = RegExp(
    r"\b(?:in|for|at)\s+([a-z][a-z .'-]*?)(?:\s+(?:today|tomorrow|now|right now|please))?[?.!]*$",
  );
  static final _email = RegExp(
    r'\b(e-?mails?|inbox|mails?|unread messages?)\b',
  );
  static final _newConv = RegExp(
    r'\b(new conversation|start over|forget (this|that|our) conversation|reset)\b',
  );
  static final _stop = RegExp(
    r'^(stop|cancel|never ?mind|be quiet|shut up|that will be all|thanks?( you)?( jarvis)?)[.!]*$',
  );

  /// Requests longer than this are sent to the cloud when it's available,
  /// because they likely ask for more than a single fact.
  static const simpleWordLimit = 10;

  RoutedIntent route(String utterance) {
    final t = _normalise(utterance);
    if (t.isEmpty) return const RoutedIntent(Intent.unknown);
    if (_stop.hasMatch(t)) return const RoutedIntent(Intent.stop);
    if (_newConv.hasMatch(t)) return const RoutedIntent(Intent.newConversation);
    if (_weather.hasMatch(t)) {
      final m = _city.firstMatch(t);
      final city = m?.group(1)?.trim();
      return RoutedIntent(
        Intent.weather,
        city: (city == null || _notACity.contains(city)) ? null : _title(city),
      );
    }
    if (_email.hasMatch(t)) return const RoutedIntent(Intent.email);
    if (_time.hasMatch(t)) return const RoutedIntent(Intent.time);
    if (_date.hasMatch(t)) return const RoutedIntent(Intent.date);
    return const RoutedIntent(Intent.unknown);
  }

  bool isSimple(String utterance) =>
      _normalise(utterance).split(' ').length <= simpleWordLimit;

  static const _notACity = {'the morning', 'the evening', 'here', 'my area'};

  static String _normalise(String s) => s
      .toLowerCase()
      .replaceFirst(RegExp(r'^(hey |ok |okay )?jarvis[, ]*'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String _title(String s) => s
      .split(' ')
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');
}
