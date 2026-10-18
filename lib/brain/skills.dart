import 'dart:convert';

import 'package:intl/intl.dart';

import '../config/settings.dart';
import '../services/cache.dart';
import '../services/mail_service.dart';
import '../services/weather_service.dart';

/// The things JARVIS can actually do. Each skill is used two ways:
///  * offline/fast path: the intent router calls it and speaks a template;
///  * cloud path: Claude calls it as a tool and phrases the answer itself.
class Skills {
  final Settings Function() settings;
  final WeatherService weather;
  final MailService mail;
  final DateTime Function() now;

  Skills({
    required this.settings,
    WeatherService? weather,
    MailService? mail,
    DateTime Function()? now,
  })  : weather = weather ?? WeatherService(),
        mail = mail ?? MailService(),
        now = now ?? DateTime.now;

  // ---- Tool definitions sent to Claude -------------------------------------

  static const toolDefinitions = <Map<String, dynamic>>[
    {
      'name': 'get_time',
      'description':
          'Get the current local date, time and weekday on the user\'s device.',
      'strict': true,
      'input_schema': {
        'type': 'object',
        'properties': {},
        'required': [],
        'additionalProperties': false,
      },
    },
    {
      'name': 'get_weather',
      'description':
          'Get current conditions and today\'s forecast. Omit city to use the '
              'user\'s home city. Result may be cached if the device is offline; '
              'check the "as_of" field.',
      'strict': true,
      'input_schema': {
        'type': 'object',
        'properties': {
          'city': {
            'type': 'string',
            'description': 'City name, e.g. "London". Empty for home city.',
          },
        },
        'required': ['city'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'check_email',
      'description':
          'Check the user\'s inbox. Returns the unread count and the sender, '
              'subject and date of the newest unread messages (no bodies).',
      'strict': true,
      'input_schema': {
        'type': 'object',
        'properties': {},
        'required': [],
        'additionalProperties': false,
      },
    },
  ];

  /// Runs a tool for Claude. Returns a JSON string; throws on failure so the
  /// caller can send `is_error: true`.
  Future<String> runTool(String name, Map<String, dynamic> input) async {
    switch (name) {
      case 'get_time':
        return jsonEncode(timeData());
      case 'get_weather':
        final r = await getWeather(input['city'] as String?);
        return jsonEncode({...r.value, 'as_of': _asOf(r)});
      case 'check_email':
        final r = await mail.checkInbox(settings());
        return jsonEncode({...r.value, 'as_of': _asOf(r)});
      default:
        throw ArgumentError('Unknown tool $name');
    }
  }

  String _asOf(Cached r) =>
      r.fromCache ? 'cached ${describeAge(r.age)} (offline)' : 'live';

  // ---- Skill implementations -----------------------------------------------

  Map<String, dynamic> timeData() {
    final t = now();
    return {
      // intl puts a narrow no-break space before AM/PM; TTS prefers a plain one.
      'time': DateFormat.jm().format(t).replaceAll('\u202f', ' '),
      'date': DateFormat.yMMMMd().format(t),
      'weekday': DateFormat.EEEE().format(t),
      'timezone': t.timeZoneName,
    };
  }

  Future<Cached<Map<String, dynamic>>> getWeather(String? city) {
    final s = settings();
    final target = (city == null || city.trim().isEmpty) ? s.city : city.trim();
    if (target.isEmpty) {
      throw WeatherException(
        'I need a home city for the weather. Please set one in settings.',
      );
    }
    return weather.getWeather(target, fahrenheit: s.useFahrenheit);
  }

  // ---- Spoken templates for the offline/fast path --------------------------

  String speakTime() {
    final d = timeData();
    return "It's ${d['time']}, ${settings().userTitle}.";
  }

  String speakDate() {
    final d = timeData();
    return "Today is ${d['weekday']}, ${d['date']}.";
  }

  Future<String> speakWeather(String? city) async {
    final r = await getWeather(city);
    final w = r.value;
    final u = '°${w['unit']}';
    final buf = StringBuffer();
    if (r.fromCache) {
      buf.write("I'm offline, so this is from ${describeAge(r.age)}. ");
    }
    buf.write(
      "In ${w['location']} it's ${_round(w['temperature'])}$u with ${w['condition']}",
    );
    if ((_round(w['feels_like']) - _round(w['temperature'])).abs() >= 3) {
      buf.write(', feeling like ${_round(w['feels_like'])}$u');
    }
    buf.write(
      '. Today: a high of ${_round(w['high'])} and a low of ${_round(w['low'])}',
    );
    final rain = w['rain_chance'];
    if (rain is num && rain >= 30) {
      buf.write(', with a ${rain.round()} percent chance of rain');
    }
    buf.write('.');
    return buf.toString();
  }

  Future<String> speakEmail() async {
    final r = await mail.checkInbox(settings());
    final m = r.value;
    final count = m['unread_count'] as int;
    final latest = (m['latest_unread'] as List).cast<Map<String, dynamic>>();
    final prefix = r.fromCache
        ? "I can't reach the mail server. As of ${describeAge(r.age)}, "
        : '';
    if (count == 0) {
      return "${prefix}You have no unread emails, ${settings().userTitle}.";
    }
    final buf = StringBuffer(
      '${prefix}You have $count unread email${count == 1 ? '' : 's'}. ',
    );
    final top = latest.take(3).toList();
    buf.write(top.length == 1 ? 'The latest is ' : 'The latest are: ');
    buf.write(
      top.map((e) => 'from ${e['from']}, "${e['subject']}"').join('; '),
    );
    buf.write('.');
    return buf.toString();
  }

  static int _round(dynamic v) => (v as num).round();
}
