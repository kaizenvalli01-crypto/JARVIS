import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Speech recognition + text-to-speech.
///  * Windows: SAPI through the app's own native channel
///    (windows/runner/native_speech.cpp). Works offline.
///  * Android: Google/Samsung recognizer and Android TTS via plugins
///    (offline once the language pack is downloaded).
abstract class SpeechService {
  factory SpeechService() =>
      Platform.isWindows ? _WindowsSpeech() : _PluginSpeech();

  bool get isReady;
  String? get lastError;

  Future<bool> init({required String locale});

  /// Listens for one utterance. [onPartial] receives live text; the
  /// returned future completes with the final text ('' if nothing heard).
  Future<String> listenOnce({
    required String locale,
    bool preferOnDevice = false,
    void Function(String text)? onPartial,
  });

  Future<void> stopListening();
  Future<void> speak(String text);
  Future<void> stopSpeaking();
}

class _WindowsSpeech implements SpeechService {
  static const _channel = MethodChannel('jarvis/windows_speech');

  /// Give up if nothing at all is heard for this long.
  static const _silenceTimeout = Duration(seconds: 8);

  /// Hard cap on one utterance.
  static const _maxListen = Duration(seconds: 30);

  bool _ready = false;
  bool _tts = false;
  String? _error;
  Completer<String>? _listening;
  Completer<void>? _speaking;
  String _latest = '';
  void Function(String)? _onPartial;
  Timer? _silence;

  @override
  bool get isReady => _ready;
  @override
  String? get lastError => _error;

  @override
  Future<bool> init({required String locale}) async {
    _channel.setMethodCallHandler(_onNativeCall);
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>(
        'init',
        {'locale': locale},
      );
      _ready = r?['recognizer'] == true;
      _tts = r?['tts'] == true;
      _error = r?['error'] as String?;
      await _channel.invokeMethod('setRate', 0.0);
    } on PlatformException catch (e) {
      _error = e.message;
    } on MissingPluginException {
      _error = 'native speech module missing';
    }
    return _ready;
  }

  Future<void> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onPartial':
        _latest = call.arguments as String? ?? '';
        _onPartial?.call(_latest);
        _resetSilence();
      case 'onFinal':
        final text = call.arguments as String? ?? '';
        if (text.isNotEmpty) _latest = text;
        _finishListening();
      case 'onNoMatch':
        _finishListening();
      case 'onSound':
        if (call.arguments == true) _resetSilence();
      case 'onSpeakDone':
        _finishSpeaking();
    }
  }

  void _resetSilence() {
    _silence?.cancel();
    _silence = Timer(_silenceTimeout, _finishListening);
  }

  void _finishListening() {
    _silence?.cancel();
    final c = _listening;
    _listening = null;
    _onPartial = null;
    if (c != null && !c.isCompleted) {
      _channel.invokeMethod('stopListening');
      c.complete(_latest);
    }
  }

  void _finishSpeaking() {
    final c = _speaking;
    _speaking = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  @override
  Future<String> listenOnce({
    required String locale,
    bool preferOnDevice = false,
    void Function(String text)? onPartial,
  }) async {
    if (!_ready) return '';
    await stopSpeaking();
    _finishListening();
    _latest = '';
    _onPartial = onPartial;
    final done = Completer<String>();
    _listening = done;
    final started = await _channel.invokeMethod<bool>('listen') ?? false;
    if (!started) {
      _error = 'The microphone could not be started';
      _finishListening();
      return '';
    }
    _resetSilence();
    return done.future.timeout(_maxListen, onTimeout: () {
      _finishListening();
      return _latest;
    });
  }

  @override
  Future<void> stopListening() async => _finishListening();

  @override
  Future<void> speak(String text) async {
    if (text.isEmpty || !_tts) return;
    _finishSpeaking();
    final done = Completer<void>();
    _speaking = done;
    await _channel.invokeMethod('speak', text);
    // Safety net in case the end-of-speech event never arrives.
    final estimate = Duration(seconds: 5 + text.length ~/ 8);
    await done.future.timeout(estimate, onTimeout: () {});
  }

  @override
  Future<void> stopSpeaking() async {
    if (_tts) await _channel.invokeMethod('stopSpeaking');
    _finishSpeaking();
  }
}

class _PluginSpeech implements SpeechService {
  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  String? _error;

  @override
  bool get isReady => _ready;
  @override
  String? get lastError => _error;

  @override
  Future<bool> init({required String locale}) async {
    try {
      _ready = await _stt.initialize(
        onError: (e) => _error = e.errorMsg,
      );
    } catch (e) {
      _error = e.toString();
      _ready = false;
    }
    await _tts.awaitSpeakCompletion(true);
    await _tts.setLanguage(locale);
    await _tts.setSpeechRate(0.5);
    await _tts.setPitch(0.95);
    return _ready;
  }

  @override
  Future<String> listenOnce({
    required String locale,
    bool preferOnDevice = false,
    void Function(String text)? onPartial,
  }) async {
    if (!_ready) return '';
    await _tts.stop();
    final done = Completer<String>();
    var latest = '';

    void finish() {
      if (!done.isCompleted) done.complete(latest);
    }

    await _stt.listen(
      onResult: (SpeechRecognitionResult r) {
        latest = r.recognizedWords;
        onPartial?.call(latest);
        if (r.finalResult) finish();
      },
      listenOptions: SpeechListenOptions(
        localeId: locale.replaceAll('-', '_'),
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
        partialResults: true,
        onDevice: preferOnDevice,
        cancelOnError: true,
        listenMode: ListenMode.confirmation,
      ),
    );

    // Some engines end without a final result; poll the listening state.
    Timer.periodic(const Duration(milliseconds: 250), (t) {
      if (done.isCompleted) {
        t.cancel();
      } else if (!_stt.isListening) {
        t.cancel();
        Future.delayed(const Duration(milliseconds: 400), finish);
      }
    });
    return done.future;
  }

  @override
  Future<void> stopListening() => _stt.stop();

  @override
  Future<void> speak(String text) async {
    if (text.isEmpty) return;
    await _tts.speak(text);
  }

  @override
  Future<void> stopSpeaking() => _tts.stop();
}
