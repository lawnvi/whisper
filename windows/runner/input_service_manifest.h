#ifndef RUNNER_INPUT_SERVICE_MANIFEST_H_
#define RUNNER_INPUT_SERVICE_MANIFEST_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

// What the lock screen input service may update itself to: a short text,
// signed in the release workflow with the key that signs update packages
// (script/sign_input_service.sh), giving a version and the SHA-512 of each
// file the service runs. Nothing here is Windows-specific, so that it can be
// checked anywhere.
//
//   whisper-input-service-v1
//   0.0.62
//   <128 lowercase hex digits> whisper.exe
//   <128 lowercase hex digits> msvcp140.dll
//   ...
namespace whisper_input_service {

struct ManifestVersion {
  uint32_t major = 0;
  uint32_t minor = 0;
  uint32_t patch = 0;
};

struct ManifestFile {
  // As shipped beside whisper.exe: one of a few known names.
  std::string name;
  std::array<uint8_t, 64> sha512{};
};

struct Manifest {
  ManifestVersion version;
  std::vector<ManifestFile> files;
};

using SigningKey = std::array<uint8_t, 32>;

constexpr size_t kMaxManifestBytes = 4096;
constexpr size_t kMaxManifestSignatureBytes = 1024;

// The Ed25519 keys whose signature makes a manifest acceptable: the same as
// `whisperUpdateSigningKeys` in lib/helper/update_signature.dart.
extern const SigningKey kManifestSigningKeys[];
extern const size_t kManifestSigningKeyCount;

// Checks [signature] (base64, as the .sig file holds it) over [text] against
// [keys], then parses [text]. False for anything but an exact, signed
// manifest that names whisper.exe.
bool VerifyManifest(const std::string& text,
                    const std::string& signature,
                    const SigningKey* keys,
                    size_t key_count,
                    Manifest* manifest);

// Whether [offered] is strictly newer than [current].
bool IsNewer(const ManifestVersion& offered, const ManifestVersion& current);

std::array<uint8_t, 64> Sha512(const void* data, size_t size);

}  // namespace whisper_input_service

#endif  // RUNNER_INPUT_SERVICE_MANIFEST_H_
