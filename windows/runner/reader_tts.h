#ifndef RUNNER_READER_TTS_H_
#define RUNNER_READER_TTS_H_

#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <sapi.h>
#include <wrl/client.h>
#include <memory>

class ReaderTts {
 public:
  explicit ReaderTts(flutter::BinaryMessenger* messenger);
  ~ReaderTts();
 private:
  void Handle(const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  Microsoft::WRL::ComPtr<ISpVoice> voice_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  bool paused_ = false;
  ULONG stream_ = 0;
  LONG word_offset_ = 0;
  ULONG word_length_ = 0;
  bool started_ = false, done_ = false;
};
#endif
