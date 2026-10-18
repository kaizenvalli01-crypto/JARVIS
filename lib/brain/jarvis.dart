import '../config/settings.dart';
import 'claude_client.dart';
import 'intent_router.dart';
import 'skills.dart';

enum ReplySource { local, cloud, offlineFallback }

class Reply {
  final String text;
  final ReplySource source;
  final bool stopSpeaking;
  const Reply(this.text, this.source, {this.stopSpeaking = false});
}

/// Decides how to answer each request:
///   1. Simple time/date/weather/email requests -> local skills (instant, offline).
///   2. Anything else -> Claude with the same skills as tools (cloud).
///   3. Cloud unreachable -> local skills if the intent is known, otherwise
///      an offline apology listing what still works.
class Jarvis {
  final Settings Function() settings;
  final Skills skills;
  final IntentRouter router;
  final ClaudeClient Function(Settings s) _clientFactory;
  ClaudeClient? _claude;

  Jarvis({
    required this.settings,
    Skills? skills,
    IntentRouter? router,
    ClaudeClient Function(Settings s)? clientFactory,
  })  : skills = skills ?? Skills(settings: settings),
        router = router ?? IntentRouter(),
        _clientFactory = clientFactory ??
            ((s) => ClaudeClient(apiKey: s.anthropicApiKey, model: s.model));

  /// Call after settings change so the next request uses the new key/model.
  void resetCloud() => _claude = null;

  String get systemPrompt {
    final s = settings();
    return 'You are JARVIS, a voice assistant with the manner of a calm, '
        'witty British butler. Address the user as "${s.userTitle}". '
        'Your replies are spoken aloud by text-to-speech, so: answer in one to '
        'three short sentences, use plain words, and never use markdown, lists, '
        'emoji, or URLs. Use your tools for the time, weather, and email '
        'instead of guessing. When summarising email, mention senders and '
        'subjects briefly; never read out long text. If a tool result says it '
        'is cached or offline, say how old the information is. '
        "The user's home city is ${s.city.isEmpty ? 'not set' : s.city}.";
  }

  Future<Reply> handle(String utterance) async {
    final text = utterance.trim();
    if (text.isEmpty) {
      return const Reply('', ReplySource.local, stopSpeaking: true);
    }
    final s = settings();
    final routed = router.route(text);

    switch (routed.intent) {
      case Intent.stop:
        return const Reply('', ReplySource.local, stopSpeaking: true);
      case Intent.newConversation:
        _claude?.reset();
        return Reply('Very good, ${s.userTitle}. A clean slate.',
            ReplySource.local);
      default:
        break;
    }

    final known = routed.intent != Intent.unknown;
    if (known && (router.isSimple(text) || !s.hasCloud)) {
      return Reply(await _runLocal(routed), ReplySource.local);
    }

    if (s.hasCloud) {
      try {
        _claude ??= _clientFactory(s);
        final answer = await _claude!.ask(
          text,
          system: systemPrompt,
          tools: Skills.toolDefinitions,
          runTool: skills.runTool,
        );
        return Reply(answer, ReplySource.cloud);
      } on ClaudeOfflineException {
        if (known) {
          return Reply(await _runLocal(routed), ReplySource.offlineFallback);
        }
        return Reply(_offlineHelp(s), ReplySource.offlineFallback);
      } on ClaudeException catch (e) {
        return Reply(e.message, ReplySource.local);
      }
    }

    return Reply(_offlineHelp(s), ReplySource.offlineFallback);
  }

  Future<String> _runLocal(RoutedIntent r) async {
    try {
      switch (r.intent) {
        case Intent.time:
          return skills.speakTime();
        case Intent.date:
          return skills.speakDate();
        case Intent.weather:
          return await skills.speakWeather(r.city);
        case Intent.email:
          return await skills.speakEmail();
        default:
          return _offlineHelp(settings());
      }
    } catch (e) {
      return '$e.'.replaceAll('..', '.');
    }
  }

  String _offlineHelp(Settings s) {
    final why = s.hasCloud
        ? "I can't reach my cloud services at the moment"
        : 'My cloud brain is switched off';
    return "$why, ${s.userTitle}. I can still tell you the time and date, "
        'the weather, or check your email.';
  }
}
