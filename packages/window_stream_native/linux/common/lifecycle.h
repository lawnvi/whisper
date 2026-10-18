// Hooks between the two halves of the library (receiver surfaces and
// capture), so neither needs the other's internals.

#ifndef WSN_COMMON_LIFECYCLE_H_
#define WSN_COMMON_LIFECYCLE_H_

namespace wsn {

// Implemented by the capture side (exports_capture.cc): stops every capture
// session and forgets the capture callback. Called by wsn_reset_all (Dart
// hot restart, app shutdown) after the surfaces are gone.
void ResetCaptures();

}  // namespace wsn

#endif  // WSN_COMMON_LIFECYCLE_H_
