import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Wraps the platform speech engines:
///  * Android: Google/Samsung on-device recognizer and Android TTS
///    (both work offline once the language pack is downloaded).
///  * Windows: Windows speech recognition and SAPI voices (offline).
class SpeechService {
  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  String? _error;

  bool get isReady => _ready;
  String? get lastError => _error;
  bool get isListening => _stt.isListening;

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

  /// Listens for one utterance. [onPartial] receives live text; the
  /// returned future completes with the final text ('' if nothing heard).
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

  Future<void> stopListening() => _stt.stop();

  Future<void> speak(String text) async {
    if (text.isEmpty) return;
    await _tts.speak(text);
  }

  Future<void> stopSpeaking() => _tts.stop();
}
