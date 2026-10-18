#include "receiver/ui_strings.h"

#include <cstdint>
#include <map>
#include <mutex>

#include "common/log.h"

namespace wsn {
namespace {

std::mutex g_mutex;
std::map<std::string, std::string> g_words = {{"volume", "Volume"}, {"mute", "Mute"}, {"unmute", "Unmute"}};

// A small reader for the one shape Dart sends: an object of string values.
class JsonReader {
 public:
  explicit JsonReader(const char* text) : p_(text) {}

  bool ReadObject(std::map<std::string, std::string>* out) {
    Skip();
    if (*p_ != '{') return false;
    p_++;
    Skip();
    if (*p_ == '}') return true;
    for (;;) {
      std::string key;
      std::string value;
      Skip();
      if (!ReadString(&key)) return false;
      Skip();
      if (*p_ != ':') return false;
      p_++;
      Skip();
      if (*p_ == '"') {
        if (!ReadString(&value)) return false;
        (*out)[key] = value;
      } else if (!SkipValue()) {
        return false;
      }
      Skip();
      if (*p_ == ',') {
        p_++;
        continue;
      }
      return *p_ == '}';
    }
  }

 private:
  void Skip() {
    while (*p_ == ' ' || *p_ == '\t' || *p_ == '\n' || *p_ == '\r') p_++;
  }

  // Numbers, true, false, null: not words, passed over.
  bool SkipValue() {
    const char* start = p_;
    while (*p_ != '\0' && *p_ != ',' && *p_ != '}' && *p_ != '{' && *p_ != '[') p_++;
    return p_ != start && *p_ != '{' && *p_ != '[';
  }

  static void Append(std::string* out, uint32_t code) {
    if (code < 0x80) {
      out->push_back(static_cast<char>(code));
    } else if (code < 0x800) {
      out->push_back(static_cast<char>(0xC0 | (code >> 6)));
      out->push_back(static_cast<char>(0x80 | (code & 0x3F)));
    } else if (code < 0x10000) {
      out->push_back(static_cast<char>(0xE0 | (code >> 12)));
      out->push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
      out->push_back(static_cast<char>(0x80 | (code & 0x3F)));
    } else {
      out->push_back(static_cast<char>(0xF0 | (code >> 18)));
      out->push_back(static_cast<char>(0x80 | ((code >> 12) & 0x3F)));
      out->push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
      out->push_back(static_cast<char>(0x80 | (code & 0x3F)));
    }
  }

  bool Hex4(uint32_t* code) {
    *code = 0;
    for (int k = 0; k < 4; k++) {
      const char c = *p_++;
      *code <<= 4;
      if (c >= '0' && c <= '9') *code |= static_cast<uint32_t>(c - '0');
      else if (c >= 'a' && c <= 'f') *code |= static_cast<uint32_t>(c - 'a' + 10);
      else if (c >= 'A' && c <= 'F') *code |= static_cast<uint32_t>(c - 'A' + 10);
      else return false;
    }
    return true;
  }

  bool ReadString(std::string* out) {
    if (*p_ != '"') return false;
    p_++;
    while (*p_ != '"') {
      if (*p_ == '\0') return false;
      if (*p_ != '\\') {
        out->push_back(*p_++);
        continue;
      }
      p_++;
      const char escape = *p_++;
      switch (escape) {
        case '"': out->push_back('"'); break;
        case '\\': out->push_back('\\'); break;
        case '/': out->push_back('/'); break;
        case 'b': out->push_back('\b'); break;
        case 'f': out->push_back('\f'); break;
        case 'n': out->push_back('\n'); break;
        case 'r': out->push_back('\r'); break;
        case 't': out->push_back('\t'); break;
        case 'u': {
          uint32_t code = 0;
          if (!Hex4(&code)) return false;
          if (code >= 0xD800 && code <= 0xDBFF && p_[0] == '\\' && p_[1] == 'u') {
            p_ += 2;
            uint32_t low = 0;
            if (!Hex4(&low)) return false;
            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
          }
          Append(out, code);
          break;
        }
        default:
          return false;
      }
    }
    p_++;
    return true;
  }

  const char* p_;
};

}  // namespace

void SetUiStrings(const char* json) {
  if (json == nullptr) return;
  std::map<std::string, std::string> values;
  if (!JsonReader(json).ReadObject(&values)) {
    WSN_LOG("strings: not a JSON object of strings");
    return;
  }
  std::lock_guard<std::mutex> lock(g_mutex);
  for (const auto& entry : values) {
    auto it = g_words.find(entry.first);
    if (it != g_words.end() && !entry.second.empty()) it->second = entry.second;
  }
}

std::string UiString(const char* key) {
  std::lock_guard<std::mutex> lock(g_mutex);
  auto it = g_words.find(key);
  return it == g_words.end() ? std::string() : it->second;
}

}  // namespace wsn
