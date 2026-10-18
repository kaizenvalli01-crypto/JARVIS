import 'package:flutter/material.dart';

import 'brain/jarvis.dart';
import 'config/settings.dart';
import 'screens/settings_screen.dart';
import 'services/speech_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await SettingsStore.load();
  runApp(JarvisApp(initialSettings: settings));
}

const _accent = Color(0xFF29D6FF);

class JarvisApp extends StatelessWidget {
  final Settings initialSettings;
  const JarvisApp({super.key, required this.initialSettings});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JARVIS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _accent,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF05090F),
        useMaterial3: true,
      ),
      home: HomeScreen(initialSettings: initialSettings),
    );
  }
}

enum AssistantState { idle, listening, thinking, speaking }

class _Line {
  final bool fromUser;
  final String text;
  final ReplySource? source;
  _Line(this.fromUser, this.text, [this.source]);
}

class HomeScreen extends StatefulWidget {
  final Settings initialSettings;
  const HomeScreen({super.key, required this.initialSettings});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late Settings _settings = widget.initialSettings;
  late final Jarvis _jarvis = Jarvis(settings: () => _settings);
  final _speech = SpeechService();
  final _lines = <_Line>[];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  AssistantState _state = AssistantState.idle;
  String _partial = '';

  @override
  void initState() {
    super.initState();
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    final ok = await _speech.init(locale: _settings.voiceLocale);
    if (!mounted) return;
    final greeting = ok
        ? 'Good ${_partOfDay()}, ${_settings.userTitle}. How may I help?'
        : 'Speech recognition is unavailable (${_speech.lastError ?? 'no engine'}). You can still type to me.';
    _add(_Line(false, greeting, ReplySource.local));
    if (_settings.city.isEmpty || !_settings.hasMail) {
      _add(_Line(false,
          'Tip: open settings to add your home city, email account and Anthropic API key.'));
    }
  }

  String _partOfDay() {
    final h = DateTime.now().hour;
    return h < 12 ? 'morning' : (h < 18 ? 'afternoon' : 'evening');
  }

  void _add(_Line l) {
    setState(() => _lines.add(l));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _onMicPressed() async {
    switch (_state) {
      case AssistantState.listening:
        await _speech.stopListening();
        return;
      case AssistantState.speaking:
        await _speech.stopSpeaking();
        setState(() => _state = AssistantState.idle);
        return;
      case AssistantState.thinking:
        return;
      case AssistantState.idle:
        break;
    }
    if (!_speech.isReady) {
      _add(_Line(false,
          'Speech recognition is unavailable (${_speech.lastError ?? 'no engine'}). You can still type to me.'));
      return;
    }
    setState(() {
      _state = AssistantState.listening;
      _partial = '';
    });
    String heard;
    try {
      heard = await _speech.listenOnce(
        locale: _settings.voiceLocale,
        preferOnDevice: _settings.preferOnDeviceSpeech,
        onPartial: (t) {
          if (mounted) setState(() => _partial = t);
        },
      );
    } catch (e) {
      heard = '';
      _add(_Line(false, 'I had trouble with the microphone: $e'));
    }
    if (!mounted) return;
    setState(() => _partial = '');
    if (heard.trim().isEmpty) {
      setState(() => _state = AssistantState.idle);
      return;
    }
    await _handle(heard);
  }

  Future<void> _onTextSubmitted(String text) async {
    if (text.trim().isEmpty || _state == AssistantState.thinking) return;
    _input.clear();
    await _speech.stopSpeaking();
    await _handle(text);
  }

  Future<void> _handle(String text) async {
    _add(_Line(true, text));
    setState(() => _state = AssistantState.thinking);
    final reply = await _jarvis.handle(text);
    if (!mounted) return;
    if (reply.stopSpeaking || reply.text.isEmpty) {
      await _speech.stopSpeaking();
      setState(() => _state = AssistantState.idle);
      return;
    }
    _add(_Line(false, reply.text, reply.source));
    setState(() => _state = AssistantState.speaking);
    await _speech.speak(reply.text);
    if (mounted) setState(() => _state = AssistantState.idle);
  }

  Future<void> _openSettings() async {
    final updated = await Navigator.of(context).push<Settings>(
      MaterialPageRoute(builder: (_) => SettingsScreen(settings: _settings)),
    );
    if (updated != null) {
      await SettingsStore.save(updated);
      setState(() => _settings = updated);
      _jarvis.resetCloud();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String get _stateLabel => switch (_state) {
        AssistantState.idle => 'Tap to speak',
        AssistantState.listening => _partial.isEmpty ? 'Listening…' : _partial,
        AssistantState.thinking => 'Thinking…',
        AssistantState.speaking => 'Tap to stop',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('J.A.R.V.I.S.',
            style: TextStyle(letterSpacing: 6, fontWeight: FontWeight.w300)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Chip(
              avatar: Icon(
                _settings.hasCloud ? Icons.cloud_done : Icons.cloud_off,
                size: 16,
              ),
              label: Text(_settings.hasCloud ? 'Cloud + offline' : 'Offline'),
              visualDensity: VisualDensity.compact,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(16),
                itemCount: _lines.length,
                itemBuilder: (_, i) => _bubble(_lines[i]),
              ),
            ),
            const SizedBox(height: 8),
            GestureDetector(onTap: _onMicPressed, child: _reactor()),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _stateLabel,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _accent, letterSpacing: 1.2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: TextField(
                controller: _input,
                onSubmitted: _onTextSubmitted,
                textInputAction: TextInputAction.send,
                decoration: InputDecoration(
                  hintText: 'Or type a command…',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: () => _onTextSubmitted(_input.text),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bubble(_Line l) {
    final align = l.fromUser ? Alignment.centerRight : Alignment.centerLeft;
    final color = l.fromUser
        ? const Color(0xFF12324A)
        : const Color(0xFF0C1622);
    final tag = switch (l.source) {
      ReplySource.cloud => 'cloud',
      ReplySource.local => 'on-device',
      ReplySource.offlineFallback => 'offline',
      null => null,
    };
    return Align(
      alignment: align,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _accent.withValues(alpha: 0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.text),
            if (tag != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(tag,
                    style: TextStyle(
                        fontSize: 10, color: _accent.withValues(alpha: 0.7))),
              ),
          ],
        ),
      ),
    );
  }

  Widget _reactor() {
    final active = _state != AssistantState.idle;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, _) {
        final glow = active ? 12 + 18 * _pulse.value : 8.0;
        return Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [
              Colors.white.withValues(alpha: 0.9),
              _accent,
              const Color(0xFF063A4F),
            ], stops: const [0.05, 0.45, 1]),
            boxShadow: [
              BoxShadow(
                color: _accent.withValues(alpha: 0.6),
                blurRadius: glow,
                spreadRadius: glow / 4,
              ),
            ],
          ),
          child: Icon(
            switch (_state) {
              AssistantState.listening => Icons.graphic_eq,
              AssistantState.thinking => Icons.hourglass_top,
              AssistantState.speaking => Icons.stop,
              AssistantState.idle => Icons.mic,
            },
            size: 44,
            color: const Color(0xFF05090F),
          ),
        );
      },
    );
  }
}
