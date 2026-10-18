import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jarvis/brain/claude_client.dart';
import 'package:jarvis/brain/intent_router.dart';
import 'package:jarvis/brain/jarvis.dart';
import 'package:jarvis/brain/skills.dart';
import 'package:jarvis/config/settings.dart';
import 'package:jarvis/services/cache.dart';
import 'package:jarvis/services/mail_service.dart';
import 'package:jarvis/services/weather_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeMail extends MailService {
  int calls = 0;
  @override
  Future<Cached<Map<String, dynamic>>> checkInbox(Settings s,
      {int maxMessages = 5}) async {
    calls++;
    return Cached({
      'unread_count': 2,
      'latest_unread': [
        {'from': 'Pepper Potts', 'subject': 'Board meeting'},
        {'from': 'Happy', 'subject': 'Car is ready'},
      ],
    }, DateTime.now());
  }
}

http.Client weatherHttp({bool fail = false}) => MockClient((req) async {
      if (fail) throw http.ClientException('offline');
      if (req.url.host.startsWith('geocoding')) {
        return http.Response(
            jsonEncode({
              'results': [
                {'name': 'London', 'latitude': 51.5, 'longitude': -0.12}
              ]
            }),
            200);
      }
      return http.Response(
          jsonEncode({
            'current': {
              'temperature_2m': 14.2,
              'apparent_temperature': 13.8,
              'relative_humidity_2m': 70,
              'weather_code': 61,
              'wind_speed_10m': 12.0,
            },
            'daily': {
              'temperature_2m_max': [16.0],
              'temperature_2m_min': [9.4],
              'precipitation_probability_max': [80],
            },
          }),
          200);
    });

/// Scripted Claude API: returns each response in turn and records requests.
class ScriptedClaude {
  final List<Map<String, dynamic>> responses;
  final requests = <Map<String, dynamic>>[];
  final bool offline;
  ScriptedClaude(this.responses, {this.offline = false});

  http.Client get client => MockClient((req) async {
        if (offline) throw http.ClientException('no network');
        requests.add(jsonDecode(req.body) as Map<String, dynamic>);
        expect(req.headers['anthropic-version'], '2023-06-01');
        return http.Response(jsonEncode(responses[requests.length - 1]), 200);
      });
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('IntentRouter', () {
    final r = IntentRouter();
    test('time / date', () {
      expect(r.route('Jarvis, what time is it?').intent, Intent.time);
      expect(r.route("what's the date today").intent, Intent.date);
    });
    test('weather with and without city', () {
      expect(r.route("what's the weather").intent, Intent.weather);
      expect(r.route("what's the weather").city, isNull);
      final w = r.route('weather in new york today');
      expect(w.intent, Intent.weather);
      expect(w.city, 'New York');
      expect(r.route('is it going to rain').intent, Intent.weather);
    });
    test('email', () {
      expect(r.route('check my email').intent, Intent.email);
      expect(r.route('any new mails?').intent, Intent.email);
      expect(r.route('do I have unread messages').intent, Intent.email);
    });
    test('control and unknown', () {
      expect(r.route('stop').intent, Intent.stop);
      expect(r.route('start over').intent, Intent.newConversation);
      expect(r.route('tell me a joke').intent, Intent.unknown);
    });
  });

  group('Skills (offline templates)', () {
    final settings = Settings(city: 'London');
    test('time uses the injected clock', () {
      final s = Skills(
          settings: () => settings, now: () => DateTime(2026, 10, 18, 15, 5));
      expect(s.speakTime(), "It's 3:05 PM, sir.");
      expect(s.speakDate(), 'Today is Sunday, October 18, 2026.');
    });

    test('weather live, then cached when offline', () async {
      final live = Skills(
          settings: () => settings,
          weather: WeatherService(client: weatherHttp()));
      final text = await live.speakWeather(null);
      expect(text, contains('In London'));
      expect(text, contains('14°C with rain'));
      expect(text, contains('80 percent chance of rain'));

      final offline = Skills(
          settings: () => settings,
          weather: WeatherService(client: weatherHttp(fail: true)));
      final cached = await offline.speakWeather(null);
      expect(cached, startsWith("I'm offline"));
      expect(cached, contains('In London'));
    });

    test('weather without city or cache explains what to do', () async {
      final s = Skills(
          settings: () => Settings(),
          weather: WeatherService(client: weatherHttp(fail: true)));
      expect(() => s.speakWeather(null), throwsA(isA<WeatherException>()));
    });

    test('email summary', () async {
      final s = Skills(settings: () => settings, mail: FakeMail());
      final text = await s.speakEmail();
      expect(text, contains('2 unread emails'));
      expect(text, contains('Pepper Potts, "Board meeting"'));
    });

    test('email not configured', () async {
      final s = Skills(settings: () => Settings());
      expect(() => s.speakEmail(), throwsA(isA<MailException>()));
    });
  });

  group('ClaudeClient', () {
    test('runs a tool round and returns the final text', () async {
      final api = ScriptedClaude([
        {
          'stop_reason': 'tool_use',
          'content': [
            {'type': 'thinking', 'thinking': '', 'signature': 'sig'},
            {
              'type': 'tool_use',
              'id': 'tu_1',
              'name': 'check_email',
              'input': {}
            },
          ],
        },
        {
          'stop_reason': 'end_turn',
          'content': [
            {'type': 'text', 'text': 'Two unread, sir. Miss Potts writes.'}
          ],
        },
      ]);
      final c = ClaudeClient(
          apiKey: 'k', model: 'claude-opus-5-5', client: api.client);
      final answer = await c.ask('anything important in my inbox?',
          system: 'sys',
          tools: Skills.toolDefinitions,
          runTool: (name, input) async => '{"unread_count":2}');
      expect(answer, 'Two unread, sir. Miss Potts writes.');

      expect(api.requests.first['model'], 'claude-opus-5-5');
      expect(api.requests.first['fallbacks'], 'default');
      final second = api.requests[1]['messages'] as List;
      // Assistant turn is replayed unchanged, including its thinking block.
      expect((second[1]['content'] as List).first['type'], 'thinking');
      final result = (second[2]['content'] as List).single;
      expect(result['tool_use_id'], 'tu_1');
      expect(result['content'], '{"unread_count":2}');
      expect(c.history.length, 4);
    });

    test('tool errors are reported with is_error', () async {
      final api = ScriptedClaude([
        {
          'stop_reason': 'tool_use',
          'content': [
            {'type': 'tool_use', 'id': 't', 'name': 'get_weather', 'input': {}}
          ],
        },
        {
          'stop_reason': 'end_turn',
          'content': [
            {'type': 'text', 'text': 'No luck.'}
          ],
        },
      ]);
      final c = ClaudeClient(apiKey: 'k', model: 'm', client: api.client);
      await c.ask('weather?',
          system: 's',
          tools: const [],
          runTool: (_, _) async => throw WeatherException('down'));
      final result =
          ((api.requests[1]['messages'] as List)[2]['content'] as List).single;
      expect(result['is_error'], true);
    });

    test('network failure throws offline and rolls back history', () async {
      final c = ClaudeClient(
          apiKey: 'k',
          model: 'm',
          client: ScriptedClaude(const [], offline: true).client);
      await expectLater(
          c.ask('hi', system: 's', tools: const [], runTool: (_, _) async => ''),
          throwsA(isA<ClaudeOfflineException>()));
      expect(c.history, isEmpty);
    });
  });

  group('Jarvis routing', () {
    Jarvis build(Settings s, ScriptedClaude api, FakeMail mail) => Jarvis(
          settings: () => s,
          skills: Skills(settings: () => s, mail: mail),
          clientFactory: (s) =>
              ClaudeClient(apiKey: 'k', model: s.model, client: api.client),
        );

    test('simple email request stays on-device even with cloud', () async {
      final api = ScriptedClaude(const []);
      final mail = FakeMail();
      final j = build(Settings(anthropicApiKey: 'k'), api, mail);
      final r = await j.handle('check my email');
      expect(r.source, ReplySource.local);
      expect(api.requests, isEmpty);
      expect(mail.calls, 1);
    });

    test('open-ended question goes to Claude', () async {
      final api = ScriptedClaude([
        {
          'stop_reason': 'end_turn',
          'content': [
            {'type': 'text', 'text': 'Certainly, sir.'}
          ],
        },
      ]);
      final j = build(Settings(anthropicApiKey: 'k'), api, FakeMail());
      final r = await j.handle('tell me a joke about Mondays');
      expect(r.source, ReplySource.cloud);
      expect(r.text, 'Certainly, sir.');
    });

    test('cloud down: known intent falls back to local skill', () async {
      final mail = FakeMail();
      final j = build(Settings(anthropicApiKey: 'k'),
          ScriptedClaude(const [], offline: true), mail);
      final r = await j.handle(
          'could you check my email and tell me if anything looks urgent please');
      expect(r.source, ReplySource.offlineFallback);
      expect(r.text, contains('2 unread emails'));
    });

    test('no cloud: unknown request gets offline help', () async {
      final j = build(Settings(), ScriptedClaude(const []), FakeMail());
      final r = await j.handle('tell me a joke');
      expect(r.source, ReplySource.offlineFallback);
      expect(r.text, contains('cloud brain is switched off'));
    });
  });
}
