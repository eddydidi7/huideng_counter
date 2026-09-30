#include "reader_tts.h"
#include <flutter/standard_method_codec.h>
#pragma warning(push)
#pragma warning(disable: 4996)  // Windows SDK SAPI helper uses GetVersionExW.
#include <sphelper.h>
#pragma warning(pop)
#include <shellapi.h>
#include <algorithm>
#include <cmath>
#include <set>
#include <string>

namespace {
using V = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Microsoft::WRL::ComPtr;

std::wstring Wide(const std::string& value) {
  if (value.empty()) return {};
  const int n = MultiByteToWideChar(CP_UTF8, 0, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  std::wstring result(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), result.data(), n);
  return result;
}
std::string Utf8(const wchar_t* value) {
  if (!value || !*value) return {};
  const int n = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0, nullptr, nullptr);
  std::string result(n, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value, -1, result.data(), n, nullptr, nullptr);
  result.pop_back();
  return result;
}
std::string String(const Map& args, const char* key) {
  const auto it = args.find(V(key));
  if (it == args.end()) return {};
  const auto* text = std::get_if<std::string>(&it->second);
  return text ? *text : std::string();
}
}

ReaderTts::ReaderTts(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<V>>(
      messenger, "org.huideng.counter/windows_tts", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    Handle(call, std::move(result));
  });
}

ReaderTts::~ReaderTts() {
  channel_->SetMethodCallHandler(nullptr);
  if (voice_) voice_->Speak(nullptr, SPF_ASYNC | SPF_PURGEBEFORESPEAK, nullptr);
}

void ReaderTts::Handle(const flutter::MethodCall<V>& call,
                      std::unique_ptr<flutter::MethodResult<V>> result) {
  const auto& method = call.method_name();
  if (method == "settings") {
    const auto opened = reinterpret_cast<INT_PTR>(ShellExecuteW(
        nullptr, L"open", L"ms-settings:speech", nullptr, nullptr, SW_SHOWNORMAL));
    if (opened <= 32) result->Error("SETTINGS_FAILED", "Windows speech settings could not be opened.");
    else result->Success(V(true));
    return;
  }
  if (!voice_ && FAILED(CoCreateInstance(CLSID_SpVoice, nullptr, CLSCTX_ALL,
      IID_PPV_ARGS(voice_.GetAddressOf())))) {
    result->Error("TTS_INIT_FAILED", "Windows speech engine could not be initialized.");
    return;
  }
  if (method == "voices") {
    flutter::EncodableList voices;
    std::set<std::wstring> seen;
    ComPtr<ISpVoice> probe;
    HRESULT hr = CoCreateInstance(CLSID_SpVoice, nullptr, CLSCTX_ALL,
                                 IID_PPV_ARGS(probe.GetAddressOf()));
    if (FAILED(hr)) { result->Error("TTS_INIT_FAILED", "Could not enumerate voices."); return; }
    // Probe real installed tokens without modifying the active playback voice.
    for (const wchar_t* category : {SPCAT_VOICES,
        L"HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Speech_OneCore\\Voices",
        L"HKEY_CURRENT_USER\\SOFTWARE\\Microsoft\\Speech_OneCore\\Voices"}) {
      ComPtr<IEnumSpObjectTokens> tokens;
      if (FAILED(SpEnumTokens(category, nullptr, nullptr, tokens.GetAddressOf()))) continue;
      ComPtr<ISpObjectToken> token;
      while (tokens->Next(1, token.ReleaseAndGetAddressOf(), nullptr) == S_OK) {
        LPWSTR id = nullptr, label = nullptr, language = nullptr;
        if (FAILED(token->GetId(&id))) continue;
        const std::wstring token_id(id);
        CoTaskMemFree(id);
        if (!seen.insert(token_id).second || FAILED(probe->SetVoice(token.Get()))) continue;
        SpGetDescription(token.Get(), &label);
        ComPtr<ISpDataKey> attributes;
        if (SUCCEEDED(token->OpenKey(L"Attributes", attributes.GetAddressOf())))
          attributes->GetStringValue(L"Language", &language);
        wchar_t locale[LOCALE_NAME_MAX_LENGTH] = {};
        if (language) LCIDToLocaleName(static_cast<LCID>(wcstoul(language, nullptr, 16)),
                                      locale, LOCALE_NAME_MAX_LENGTH, 0);
        voices.emplace_back(Map{{V("id"), V(Utf8(token_id.c_str()))},
            {V("name"), V(label ? Utf8(label) : Utf8(token_id.c_str()))},
            {V("language"), V(Utf8(locale))}});
        CoTaskMemFree(label);
        CoTaskMemFree(language);
      }
    }
    result->Success(V(voices));
    return;
  }
  const Map empty;
  const auto* provided = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
  const auto& args = provided ? *provided : empty;
  HRESULT hr = S_OK;
  if (method == "speak") {
    const ULONGLONG interest = SPFEI(SPEI_START_INPUT_STREAM) |
        SPFEI(SPEI_WORD_BOUNDARY) | SPFEI(SPEI_END_INPUT_STREAM);
    hr = voice_->SetInterest(interest, interest);
    if (FAILED(hr)) { result->Error("TTS_FAILED", "Speech events unavailable."); return; }
    const auto text = Wide(String(args, "text"));
    const auto id = Wide(String(args, "voice"));
    if (text.empty() || text.size() > 1000 || id.empty()) {
      result->Error("INVALID_SPEECH", "Empty speech, invalid voice or oversized segment."); return;
    }
    ComPtr<ISpObjectToken> token;
    hr = SpGetTokenFromId(id.c_str(), token.GetAddressOf(), FALSE);
    if (SUCCEEDED(hr)) hr = voice_->SetVoice(token.Get());
    double rate = 1.0;
    const auto found = args.find(V("rate"));
    if (found != args.end()) {
      if (const auto* v = std::get_if<double>(&found->second)) rate = *v;
    }
    // SAPI uses -10..10 instead of a multiplier; preserve the shared 0.3..3 UI.
    const LONG sapi_rate = static_cast<LONG>(std::clamp(std::lround(
        10.0 * std::log(std::clamp(rate, 0.3, 3.0)) / std::log(3.0)), -10L, 10L));
    if (SUCCEEDED(hr)) hr = voice_->SetRate(sapi_rate);
    if (paused_) { voice_->Resume(); paused_ = false; }
    word_offset_ = 0;
    word_length_ = 0;
    started_ = done_ = false;
    if (SUCCEEDED(hr)) hr = voice_->Speak(text.c_str(),
        SPF_ASYNC | SPF_PURGEBEFORESPEAK | SPF_IS_NOT_XML, &stream_);
  } else if (method == "pause") {
    if (!paused_) { hr = voice_->Pause(); paused_ = SUCCEEDED(hr); }
  } else if (method == "resume") {
    if (paused_) { hr = voice_->Resume(); if (SUCCEEDED(hr)) paused_ = false; }
  } else if (method == "stop") {
    if (paused_) { voice_->Resume(); paused_ = false; }
    hr = voice_->Speak(nullptr, SPF_ASYNC | SPF_PURGEBEFORESPEAK, nullptr);
    stream_ = 0;
    started_ = done_ = false;
    word_offset_ = 0;
    word_length_ = 0;
  } else if (method == "status") {
    // SAPI fires these when audio is output. Ignore events from purged streams;
    // GetStatus alone can still describe the previous utterance after Speak.
    SPEVENT event{};
    while (voice_->GetEvents(1, &event, nullptr) == S_OK) {
      if (stream_ != 0 && event.ulStreamNum == stream_) {
        if (event.eEventId == SPEI_START_INPUT_STREAM) started_ = true;
        if (event.eEventId == SPEI_WORD_BOUNDARY) {
          started_ = true;
          word_offset_ = static_cast<LONG>(event.lParam);
          word_length_ = static_cast<ULONG>(event.wParam);
        }
        if (event.eEventId == SPEI_END_INPUT_STREAM) done_ = true;
      }
      SpClearEvent(&event);
    }
    SPVOICESTATUS status{};
    hr = voice_->GetStatus(&status, nullptr);
    if (SUCCEEDED(hr) && FAILED(status.hrLastResult)) hr = status.hrLastResult;
    if (SUCCEEDED(hr)) {
      result->Success(V(Map{
        {V("done"), V(!paused_ && done_)},
        {V("started"), V(started_)},
        {V("length"), V(static_cast<int64_t>(word_length_))},
        {V("offset"), V(static_cast<int64_t>(word_offset_))}}));
      return;
    }
  } else { result->NotImplemented(); return; }
  if (FAILED(hr)) result->Error("TTS_FAILED", "Windows voice is unavailable or playback failed.");
  else result->Success(V(true));
}
