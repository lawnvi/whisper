#include "common/dl.h"

namespace wsn {

void* OpenFirst(std::initializer_list<const char*> names, std::string* opened) {
  for (const char* name : names) {
    if (void* handle = dlopen(name, RTLD_NOW | RTLD_LOCAL)) {
      if (opened != nullptr) *opened = name;
      return handle;
    }
  }
  return nullptr;
}

void* Open(const std::string& name) { return dlopen(name.c_str(), RTLD_NOW | RTLD_LOCAL); }

}  // namespace wsn
