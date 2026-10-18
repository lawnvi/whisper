#include "common/pulse.h"

#include "common/dl.h"
#include "common/log.h"

namespace wsn {

const Pulse& PulseApi() {
  static const Pulse api = [] {
    Pulse p;
    void* simple = OpenFirst({"libpulse-simple.so.0", "libpulse-simple.so"});
    void* pulse = OpenFirst({"libpulse.so.0", "libpulse.so"});
    if (simple == nullptr) {
      WSN_LOG("pulse: libpulse-simple not found");
      return p;
    }
    bool ok = true;
    Sym(simple, "pa_simple_new", &p.create, &ok);
    Sym(simple, "pa_simple_write", &p.write, &ok);
    Sym(simple, "pa_simple_flush", &p.flush, &ok);
    Sym(simple, "pa_simple_get_latency", &p.latency, &ok);
    Sym(simple, "pa_simple_drain", &p.drain, &ok);
    Sym(simple, "pa_simple_free", &p.destroy, &ok);
    Sym(pulse, "pa_strerror", &p.strerror);
    p.ok = ok;
    return p;
  }();
  return api;
}

}  // namespace wsn
