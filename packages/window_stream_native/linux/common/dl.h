// Run-time loading of optional system libraries (FFmpeg, PulseAudio,
// PipeWire…), so the package has no hard link dependency on them.

#ifndef WSN_COMMON_DL_H_
#define WSN_COMMON_DL_H_

#include <dlfcn.h>

#include <initializer_list>
#include <string>

namespace wsn {

// dlopens the first library of `names` that loads (RTLD_NOW | RTLD_LOCAL).
// `opened`, if given, receives the name that loaded.
void* OpenFirst(std::initializer_list<const char*> names, std::string* opened = nullptr);

// dlopens `name` (RTLD_NOW | RTLD_LOCAL), or null.
void* Open(const std::string& name);

// Looks `name` up in `handle` into `*out` (as its function pointer type).
// Returns whether it was found; `*ok` is cleared when not, so a whole table
// can be filled and checked once.
template <typename T>
bool Sym(void* handle, const char* name, T* out, bool* ok = nullptr) {
  void* symbol = handle != nullptr ? dlsym(handle, name) : nullptr;
  *out = reinterpret_cast<T>(symbol);
  if (symbol == nullptr && ok != nullptr) *ok = false;
  return symbol != nullptr;
}

}  // namespace wsn

#endif  // WSN_COMMON_DL_H_
