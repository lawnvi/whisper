#include "input_service_manifest.h"

#include <cstring>

#include "optional/monocypher-ed25519.h"

namespace whisper_input_service {

// v2ixE8F2Qro9mOH1JQkjOorJ1PUSEmQ7FOtpQ5e7gz4=
const SigningKey kManifestSigningKeys[] = {
    {0xbf, 0x68, 0xb1, 0x13, 0xc1, 0x76, 0x42, 0xba, 0x3d, 0x98, 0xe1,
     0xf5, 0x25, 0x09, 0x23, 0x3a, 0x8a, 0xc9, 0xd4, 0xf5, 0x12, 0x12,
     0x64, 0x3b, 0x14, 0xeb, 0x69, 0x43, 0x97, 0xbb, 0x83, 0x3e},
};
const size_t kManifestSigningKeyCount =
    sizeof(kManifestSigningKeys) / sizeof(kManifestSigningKeys[0]);

namespace {

// Distinct from the update packages' "whisper-update-v1", so that neither
// signature can stand for the other.
constexpr char kHeader[] = "whisper-input-service-v1\n";
constexpr char kExecutable[] = "whisper.exe";
constexpr const char* kAllowedNames[] = {
    kExecutable,
    "msvcp140.dll",
    "vcruntime140.dll",
    "vcruntime140_1.dll",
};

bool ParseNumber(const std::string& text, uint32_t* value) {
  if (text.empty() || text.size() > 9 || (text.size() > 1 && text[0] == '0')) {
    return false;
  }
  uint32_t result = 0;
  for (const char c : text) {
    if (c < '0' || c > '9') {
      return false;
    }
    result = result * 10 + static_cast<uint32_t>(c - '0');
  }
  *value = result;
  return true;
}

bool ParseVersion(const std::string& line, ManifestVersion* version) {
  const size_t first = line.find('.');
  if (first == std::string::npos) {
    return false;
  }
  const size_t second = line.find('.', first + 1);
  if (second == std::string::npos ||
      line.find('.', second + 1) != std::string::npos) {
    return false;
  }
  return ParseNumber(line.substr(0, first), &version->major) &&
         ParseNumber(line.substr(first + 1, second - first - 1),
                     &version->minor) &&
         ParseNumber(line.substr(second + 1), &version->patch);
}

int HexDigit(char c) {
  if (c >= '0' && c <= '9') {
    return c - '0';
  }
  if (c >= 'a' && c <= 'f') {
    return c - 'a' + 10;
  }
  return -1;
}

bool ParseFile(const std::string& line, ManifestFile* file) {
  constexpr size_t kHexDigits = 128;
  if (line.size() <= kHexDigits + 1 || line[kHexDigits] != ' ') {
    return false;
  }
  for (size_t i = 0; i < file->sha512.size(); ++i) {
    const int high = HexDigit(line[2 * i]);
    const int low = HexDigit(line[2 * i + 1]);
    if (high < 0 || low < 0) {
      return false;
    }
    file->sha512[i] = static_cast<uint8_t>(high << 4 | low);
  }
  file->name = line.substr(kHexDigits + 1);
  for (const char* allowed : kAllowedNames) {
    if (file->name == allowed) {
      return true;
    }
  }
  return false;
}

int Base64Digit(char c) {
  if (c >= 'A' && c <= 'Z') {
    return c - 'A';
  }
  if (c >= 'a' && c <= 'z') {
    return c - 'a' + 26;
  }
  if (c >= '0' && c <= '9') {
    return c - '0' + 52;
  }
  if (c == '+') {
    return 62;
  }
  if (c == '/') {
    return 63;
  }
  return -1;
}

// Standard base64 with padding, as `base64` writes it, allowing the line end
// an editor might add.
bool DecodeBase64(std::string text, std::vector<uint8_t>* bytes) {
  while (!text.empty() && (text.back() == '\n' || text.back() == '\r')) {
    text.pop_back();
  }
  if (text.empty() || text.size() % 4 != 0) {
    return false;
  }
  bytes->clear();
  uint32_t buffer = 0;
  int bits = 0;
  size_t padding = 0;
  for (size_t i = 0; i < text.size(); ++i) {
    if (text[i] == '=') {
      if (i + 2 < text.size()) {
        return false;
      }
      ++padding;
      continue;
    }
    const int digit = Base64Digit(text[i]);
    if (digit < 0 || padding > 0) {
      return false;
    }
    buffer = (buffer << 6) | static_cast<uint32_t>(digit);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      bytes->push_back(static_cast<uint8_t>(buffer >> bits));
      buffer &= (1u << bits) - 1;
    }
  }
  return true;
}

bool Signed(const std::string& text,
            const std::string& signature,
            const SigningKey* keys,
            size_t key_count) {
  std::vector<uint8_t> bytes;
  if (!DecodeBase64(signature, &bytes) || bytes.size() != 64) {
    return false;
  }
  for (size_t i = 0; i < key_count; ++i) {
    if (crypto_ed25519_check(bytes.data(), keys[i].data(),
                             reinterpret_cast<const uint8_t*>(text.data()),
                             text.size()) == 0) {
      return true;
    }
  }
  return false;
}

}  // namespace

bool VerifyManifest(const std::string& text,
                    const std::string& signature,
                    const SigningKey* keys,
                    size_t key_count,
                    Manifest* manifest) {
  const size_t header = std::strlen(kHeader);
  if (text.size() > kMaxManifestBytes ||
      signature.size() > kMaxManifestSignatureBytes ||
      text.compare(0, header, kHeader) != 0 || text.back() != '\n' ||
      !Signed(text, signature, keys, key_count)) {
    return false;
  }
  Manifest parsed;
  bool has_version = false;
  bool has_executable = false;
  size_t start = header;
  while (start < text.size()) {
    const size_t end = text.find('\n', start);
    const std::string line = text.substr(start, end - start);
    start = end + 1;
    if (!has_version) {
      if (!ParseVersion(line, &parsed.version)) {
        return false;
      }
      has_version = true;
      continue;
    }
    ManifestFile file;
    if (!ParseFile(line, &file)) {
      return false;
    }
    for (const ManifestFile& seen : parsed.files) {
      if (seen.name == file.name) {
        return false;
      }
    }
    has_executable = has_executable || file.name == kExecutable;
    parsed.files.push_back(file);
  }
  if (!has_executable) {
    return false;
  }
  *manifest = parsed;
  return true;
}

bool IsNewer(const ManifestVersion& offered, const ManifestVersion& current) {
  if (offered.major != current.major) {
    return offered.major > current.major;
  }
  if (offered.minor != current.minor) {
    return offered.minor > current.minor;
  }
  return offered.patch > current.patch;
}

std::array<uint8_t, 64> Sha512(const void* data, size_t size) {
  std::array<uint8_t, 64> hash{};
  crypto_sha512(hash.data(), static_cast<const uint8_t*>(data), size);
  return hash;
}

}  // namespace whisper_input_service
