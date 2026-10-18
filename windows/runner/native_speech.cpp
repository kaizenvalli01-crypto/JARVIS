#include "native_speech.h"

#include <flutter/standard_method_codec.h>

#include <cstdio>
#include <cwchar>
#include <utility>

using Microsoft::WRL::ComPtr;

namespace {

constexpr UINT kRecognizerMessage = WM_APP + 0x51;
constexpr UINT kVoiceMessage = WM_APP + 0x52;

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) return std::wstring();
  int size = MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                 static_cast<int>(text.size()), nullptr, 0);
  std::wstring wide(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      wide.data(), size);
  return wide;
}

std::string WideToUtf8(const wchar_t* text) {
  if (text == nullptr || *text == L'\0') return std::string();
  int size =
      WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
  if (size <= 1) return std::string();
  std::string utf8(static_cast<size_t>(size - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, utf8.data(), size, nullptr,
                      nullptr);
  return utf8;
}

std::string HResultMessage(const char* what, HRESULT hr) {
  char buffer[160];
  snprintf(buffer, sizeof(buffer), "%s (0x%08lX)", what,
           static_cast<unsigned long>(hr));
  return buffer;
}

// Frees whatever an SPEVENT's lParam owns (what SpClearEvent does in
// sphelper.h, which we avoid because it doesn't compile cleanly with /WX).
void ClearEvent(SPEVENT* event) {
  if (event->lParam != 0) {
    switch (event->elParamType) {
      case SPET_LPARAM_IS_OBJECT:
      case SPET_LPARAM_IS_TOKEN:
        reinterpret_cast<IUnknown*>(event->lParam)->Release();
        break;
      case SPET_LPARAM_IS_POINTER:
      case SPET_LPARAM_IS_STRING:
        CoTaskMemFree(reinterpret_cast<void*>(event->lParam));
        break;
      default:
        break;
    }
  }
  ZeroMemory(event, sizeof(*event));
}

std::string PhraseText(SPEVENT* event) {
  if (event->elParamType != SPET_LPARAM_IS_OBJECT || event->lParam == 0) {
    return std::string();
  }
  auto* result = reinterpret_cast<ISpRecoResult*>(event->lParam);
  wchar_t* text = nullptr;
  std::string utf8;
  if (SUCCEEDED(result->GetText(static_cast<ULONG>(SP_GETWHOLEPHRASE),
                                static_cast<ULONG>(SP_GETWHOLEPHRASE), TRUE,
                                &text, nullptr)) &&
      text != nullptr) {
    utf8 = WideToUtf8(text);
    CoTaskMemFree(text);
  }
  return utf8;
}

// Finds a token in |category| for |locale| (e.g. "en-GB"), falling back to
// the category's default token (the one chosen in Windows settings).
HRESULT FindToken(const wchar_t* category, const std::wstring& locale,
                  ComPtr<ISpObjectToken>* token) {
  ComPtr<ISpObjectTokenCategory> cat;
  HRESULT hr = CoCreateInstance(CLSID_SpObjectTokenCategory, nullptr,
                                CLSCTX_ALL, IID_PPV_ARGS(&cat));
  if (FAILED(hr)) return hr;
  hr = cat->SetId(category, FALSE);
  if (FAILED(hr)) return hr;

  LCID lcid = locale.empty() ? 0 : LocaleNameToLCID(locale.c_str(), 0);
  if (lcid != 0) {
    wchar_t required[48];
    swprintf(required, 48, L"Language=%x", static_cast<unsigned int>(lcid));
    ComPtr<IEnumSpObjectTokens> tokens;
    if (SUCCEEDED(cat->EnumTokens(required, nullptr, &tokens))) {
      ComPtr<ISpObjectToken> match;
      if (tokens->Next(1, &match, nullptr) == S_OK) {
        *token = match;
        return S_OK;
      }
    }
  }

  wchar_t* id = nullptr;
  hr = cat->GetDefaultTokenId(&id);
  if (FAILED(hr)) return hr;
  ComPtr<ISpObjectToken> fallback;
  hr = CoCreateInstance(CLSID_SpObjectToken, nullptr, CLSCTX_ALL,
                        IID_PPV_ARGS(&fallback));
  if (SUCCEEDED(hr)) hr = fallback->SetId(nullptr, id, FALSE);
  CoTaskMemFree(id);
  if (SUCCEEDED(hr)) *token = fallback;
  return hr;
}

}  // namespace

NativeSpeech::NativeSpeech(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "jarvis/windows_speech",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

NativeSpeech::~NativeSpeech() {
  channel_->SetMethodCallHandler(nullptr);
  StopListening();
  if (voice_) voice_->SetNotifySink(nullptr);
  if (context_) context_->SetNotifySink(nullptr);
}

void NativeSpeech::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();

  if (method == "init") {
    std::wstring locale;
    if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
      auto it = args->find(flutter::EncodableValue("locale"));
      if (it != args->end()) {
        if (const auto* s = std::get_if<std::string>(&it->second)) {
          locale = Utf8ToWide(*s);
        }
      }
    }
    std::string reco_error;
    std::string voice_error;
    bool reco_ok = InitRecognizer(locale, &reco_error);
    bool voice_ok = InitVoice(locale, &voice_error);
    flutter::EncodableMap response{
        {flutter::EncodableValue("recognizer"), flutter::EncodableValue(reco_ok)},
        {flutter::EncodableValue("tts"), flutter::EncodableValue(voice_ok)},
    };
    std::string error = reco_error.empty() ? voice_error : reco_error;
    if (!error.empty()) {
      response[flutter::EncodableValue("error")] = flutter::EncodableValue(error);
    }
    result->Success(flutter::EncodableValue(response));
  } else if (method == "listen") {
    result->Success(flutter::EncodableValue(StartListening()));
  } else if (method == "stopListening") {
    StopListening();
    result->Success();
  } else if (method == "speak") {
    if (const auto* text = std::get_if<std::string>(call.arguments())) {
      Speak(*text);
    }
    result->Success();
  } else if (method == "stopSpeaking") {
    StopSpeaking();
    result->Success();
  } else if (method == "setRate") {
    if (const auto* rate = std::get_if<double>(call.arguments())) {
      if (voice_) voice_->SetRate(static_cast<long>(*rate));
    }
    result->Success();
  } else {
    result->NotImplemented();
  }
}

bool NativeSpeech::InitRecognizer(const std::wstring& locale,
                                  std::string* error) {
  if (grammar_) return true;

  ComPtr<ISpRecognizer> recognizer;
  HRESULT hr = CoCreateInstance(CLSID_SpInprocRecognizer, nullptr, CLSCTX_ALL,
                                IID_PPV_ARGS(&recognizer));
  if (FAILED(hr)) {
    *error = HResultMessage("Windows speech recognition is unavailable", hr);
    return false;
  }

  ComPtr<ISpObjectToken> engine;
  hr = FindToken(SPCAT_RECOGNIZERS, locale, &engine);
  if (SUCCEEDED(hr)) hr = recognizer->SetRecognizer(engine.Get());
  if (FAILED(hr)) {
    *error = HResultMessage(
        "No Windows speech recognizer is installed. Add a speech language "
        "in Settings > Time & language > Speech",
        hr);
    return false;
  }

  ComPtr<ISpAudio> audio;
  hr = CoCreateInstance(CLSID_SpMMAudioIn, nullptr, CLSCTX_ALL,
                        IID_PPV_ARGS(&audio));
  if (SUCCEEDED(hr)) hr = recognizer->SetInput(audio.Get(), TRUE);
  if (FAILED(hr)) {
    *error = HResultMessage("Could not open the microphone", hr);
    return false;
  }

  ComPtr<ISpRecoContext> context;
  hr = recognizer->CreateRecoContext(&context);
  if (SUCCEEDED(hr)) {
    hr = context->SetNotifyWindowMessage(window_, kRecognizerMessage, 0, 0);
  }
  if (SUCCEEDED(hr)) {
    const ULONGLONG interest =
        SPFEI(SPEI_RECOGNITION) | SPFEI(SPEI_HYPOTHESIS) |
        SPFEI(SPEI_FALSE_RECOGNITION) | SPFEI(SPEI_SOUND_START) |
        SPFEI(SPEI_SOUND_END);
    hr = context->SetInterest(interest, interest);
  }
  ComPtr<ISpRecoGrammar> grammar;
  if (SUCCEEDED(hr)) hr = context->CreateGrammar(0, &grammar);
  if (SUCCEEDED(hr)) hr = grammar->LoadDictation(nullptr, SPLO_STATIC);
  if (SUCCEEDED(hr)) hr = grammar->SetDictationState(SPRS_INACTIVE);
  // Keep the microphone closed until the user taps the button.
  if (SUCCEEDED(hr)) hr = recognizer->SetRecoState(SPRST_INACTIVE);
  if (FAILED(hr)) {
    *error = HResultMessage("Could not start speech dictation", hr);
    return false;
  }

  recognizer_ = recognizer;
  context_ = context;
  grammar_ = grammar;
  return true;
}

bool NativeSpeech::InitVoice(const std::wstring& locale, std::string* error) {
  if (voice_) return true;

  ComPtr<ISpVoice> voice;
  HRESULT hr =
      CoCreateInstance(CLSID_SpVoice, nullptr, CLSCTX_ALL, IID_PPV_ARGS(&voice));
  if (FAILED(hr)) {
    *error = HResultMessage("Windows text-to-speech is unavailable", hr);
    return false;
  }
  ComPtr<ISpObjectToken> token;
  if (SUCCEEDED(FindToken(SPCAT_VOICES, locale, &token))) {
    voice->SetVoice(token.Get());
  }
  hr = voice->SetNotifyWindowMessage(window_, kVoiceMessage, 0, 0);
  if (SUCCEEDED(hr)) {
    const ULONGLONG interest = SPFEI(SPEI_END_INPUT_STREAM);
    hr = voice->SetInterest(interest, interest);
  }
  if (FAILED(hr)) {
    *error = HResultMessage("Could not set up text-to-speech", hr);
    return false;
  }
  voice_ = voice;
  return true;
}

bool NativeSpeech::StartListening() {
  if (!grammar_ || !recognizer_) return false;
  if (listening_) return true;
  StopSpeaking();
  HRESULT hr = grammar_->SetDictationState(SPRS_ACTIVE);
  if (SUCCEEDED(hr)) hr = recognizer_->SetRecoState(SPRST_ACTIVE);
  if (FAILED(hr)) {
    grammar_->SetDictationState(SPRS_INACTIVE);
    return false;
  }
  listening_ = true;
  return true;
}

void NativeSpeech::StopListening() {
  if (!listening_) return;
  listening_ = false;
  if (grammar_) grammar_->SetDictationState(SPRS_INACTIVE);
  if (recognizer_) recognizer_->SetRecoState(SPRST_INACTIVE);
}

void NativeSpeech::Speak(const std::string& text) {
  if (!voice_) {
    Send("onSpeakDone");
    return;
  }
  std::wstring wide = Utf8ToWide(text);
  ULONG stream = 0;
  HRESULT hr = voice_->Speak(
      wide.c_str(), SPF_ASYNC | SPF_PURGEBEFORESPEAK | SPF_IS_NOT_XML, &stream);
  if (FAILED(hr)) {
    Send("onSpeakDone");
    return;
  }
  current_stream_ = stream;
}

void NativeSpeech::StopSpeaking() {
  if (!voice_) return;
  current_stream_ = 0;
  voice_->Speak(nullptr, SPF_ASYNC | SPF_PURGEBEFORESPEAK, nullptr);
}

bool NativeSpeech::HandleWindowMessage(UINT message) {
  if (message == kRecognizerMessage) {
    DrainRecognizerEvents();
    return true;
  }
  if (message == kVoiceMessage) {
    DrainVoiceEvents();
    return true;
  }
  return false;
}

void NativeSpeech::DrainRecognizerEvents() {
  if (!context_) return;
  SPEVENT event;
  ZeroMemory(&event, sizeof(event));
  ULONG fetched = 0;
  while (context_->GetEvents(1, &event, &fetched) == S_OK && fetched == 1) {
    // Late events can arrive just after the user stopped; ignore them.
    if (listening_) {
      switch (static_cast<SPEVENTENUM>(event.eEventId)) {
        case SPEI_HYPOTHESIS:
          Send("onPartial",
               std::make_unique<flutter::EncodableValue>(PhraseText(&event)));
          break;
        case SPEI_RECOGNITION:
          Send("onFinal",
               std::make_unique<flutter::EncodableValue>(PhraseText(&event)));
          break;
        case SPEI_FALSE_RECOGNITION:
          Send("onNoMatch");
          break;
        case SPEI_SOUND_START:
          Send("onSound", std::make_unique<flutter::EncodableValue>(true));
          break;
        case SPEI_SOUND_END:
          Send("onSound", std::make_unique<flutter::EncodableValue>(false));
          break;
        default:
          break;
      }
    }
    ClearEvent(&event);
  }
}

void NativeSpeech::DrainVoiceEvents() {
  if (!voice_) return;
  SPEVENT event;
  ZeroMemory(&event, sizeof(event));
  ULONG fetched = 0;
  while (voice_->GetEvents(1, &event, &fetched) == S_OK && fetched == 1) {
    if (static_cast<SPEVENTENUM>(event.eEventId) == SPEI_END_INPUT_STREAM &&
        event.ulStreamNum == current_stream_) {
      current_stream_ = 0;
      Send("onSpeakDone");
    }
    ClearEvent(&event);
  }
}

void NativeSpeech::Send(const std::string& method,
                        std::unique_ptr<flutter::EncodableValue> args) {
  channel_->InvokeMethod(method, std::move(args));
}
