#ifndef RUNNER_NATIVE_SPEECH_H_
#define RUNNER_NATIVE_SPEECH_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <sapi.h>
#include <windows.h>
#include <wrl/client.h>

#include <memory>
#include <string>

// Speech recognition and text-to-speech for Windows using SAPI.
//
// Everything runs on the platform (UI) thread: SAPI posts a window message
// when events are ready, and the window procedure forwards it to
// HandleWindowMessage, which drains the events and calls into Dart. This
// avoids touching COM objects or the Flutter channel from other threads.
//
// Dart channel "jarvis/windows_speech":
//   init({locale}) -> {recognizer: bool, tts: bool, error: String?}
//   listen() -> bool, stopListening(), speak(String), stopSpeaking(),
//   setRate(double)
// Calls back: onPartial(String), onFinal(String), onNoMatch(),
//   onSound(bool), onSpeakDone()
class NativeSpeech {
 public:
  NativeSpeech(flutter::BinaryMessenger* messenger, HWND window);
  ~NativeSpeech();

  // Returns true if |message| was a speech notification and was handled.
  bool HandleWindowMessage(UINT message);

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  bool InitRecognizer(const std::wstring& locale, std::string* error);
  bool InitVoice(const std::wstring& locale, std::string* error);
  bool StartListening();
  void StopListening();
  void Speak(const std::string& text);
  void StopSpeaking();

  void DrainRecognizerEvents();
  void DrainVoiceEvents();
  void Send(const std::string& method,
            std::unique_ptr<flutter::EncodableValue> args = nullptr);

  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  Microsoft::WRL::ComPtr<ISpRecognizer> recognizer_;
  Microsoft::WRL::ComPtr<ISpRecoContext> context_;
  Microsoft::WRL::ComPtr<ISpRecoGrammar> grammar_;
  Microsoft::WRL::ComPtr<ISpVoice> voice_;
  ULONG current_stream_ = 0;
  bool listening_ = false;
};

#endif  // RUNNER_NATIVE_SPEECH_H_
