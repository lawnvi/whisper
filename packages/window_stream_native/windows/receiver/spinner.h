// The indeterminate progress ring of Windows (Fluent / WinUI ProgressRing):
// one arc that keeps rotating while it grows and shrinks.

#pragma once

#include "../common/wsn_common.h"

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace wsn {

// Ring size in DIPs (WinUI's default ring is 32 with a 4 px stroke; a
// little larger suits a video window).
constexpr float kSpinnerDiameter = 40.0f;
constexpr float kSpinnerStroke = 4.0f;
// The app's icon shown over the dark background while a window loads, and
// the gap between it and the spinner below it (DIPs).
constexpr float kPlaceholderIcon = 64.0f;
constexpr float kPlaceholderGap = 20.0f;

// The arc at `seconds` since the spinner appeared: start angle and sweep in
// degrees, clockwise from 12 o'clock.
inline void SpinnerArc(double seconds, double* start, double* sweep) {
  constexpr double kCycle = 1.6;      // grow + shrink
  constexpr double kTurn = 1.5;       // one full rotation of the whole ring
  constexpr double kMin = 12;         // shortest arc
  constexpr double kGrowth = 260;     // what the arc gains and loses per cycle
  const double cycles = seconds / kCycle;
  const double index = std::floor(cycles);
  const double u = cycles - index;
  auto ease = [](double t) {
    t = std::clamp(t, 0.0, 1.0);
    return t < 0.5 ? 4 * t * t * t : 1 - std::pow(-2 * t + 2, 3) / 2;
  };
  const double base = seconds * 360.0 / kTurn + kGrowth * index;
  const double head = base + kMin + kGrowth * ease(u * 2);
  const double tail = base + kGrowth * ease(u * 2 - 1);
  *start = std::fmod(tail, 360.0);
  *sweep = head - tail;
}

// The ring's colour: the accent's light shade (what WinUI uses on dark
// surfaces), from the user's accent palette; Windows blue without one.
inline COLORREF SpinnerColor() {
  BYTE palette[32] = {};
  DWORD size = sizeof(palette);
  if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Accent",
                   L"AccentPalette", RRF_RT_REG_BINARY, nullptr, palette, &size) == ERROR_SUCCESS &&
      size >= 8) {
    // Light3, Light2, Light1, Base, Dark1…, 4 bytes (R, G, B, A) each.
    return RGB(palette[4], palette[5], palette[6]);
  }
  return RGB(0x60, 0xCD, 0xFF);
}

}  // namespace wsn
