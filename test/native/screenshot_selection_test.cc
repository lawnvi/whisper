#include "../../native/screenshot_selection.h"

#include <cassert>
#include <iostream>

using whisper::CapturePoint;
using whisper::CaptureRect;
using whisper::ScreenshotSelection;

void ExpectRect(const ScreenshotSelection& selection, CaptureRect expected) {
  const auto actual = selection.rect();
  assert(actual.left == expected.left && actual.top == expected.top);
  assert(actual.right == expected.right && actual.bottom == expected.bottom);
}

int main() {
  ScreenshotSelection selection;
  selection.Reset(1920, 1080);
  selection.Begin({400, 300});
  selection.Update({100, 100});
  assert(selection.dragging() && !selection.selected());
  selection.End({100, 100});
  assert(!selection.dragging() && selection.selected());
  ExpectRect(selection, {100, 100, 400, 300});

  // All eight handles are distinct; mouse-up retains the editable rectangle.
  const CapturePoint handles[] = {{100, 100}, {250, 100}, {400, 100}, {100, 200},
                                  {400, 200}, {100, 300}, {250, 300}, {400, 300}};
  const int hits[] = {5, 4, 6, 1, 2, 9, 8, 10};
  for (int i = 0; i < 8; ++i) assert(selection.HitTest(handles[i]) == hits[i]);

  selection.Begin({250, 200});
  selection.End({400, 250});
  ExpectRect(selection, {250, 150, 550, 350});
  selection.Begin({400, 250});
  selection.End({-100, -100});
  ExpectRect(selection, {0, 0, 300, 200});
  selection.Begin({150, 100});
  selection.End({3000, 3000});
  ExpectRect(selection, {1620, 880, 1920, 1080});

  selection.Begin({1620, 880});
  selection.End({1600, 800});
  ExpectRect(selection, {1600, 800, 1920, 1080});
  selection.Begin({1600, 940});
  selection.End({1800, 940});
  ExpectRect(selection, {1800, 800, 1920, 1080});
  selection.Begin({1920, 940});
  selection.End({1700, 940});
  ExpectRect(selection, {1700, 800, 1800, 1080});

  // Clicking outside redraws; a click/accidental one-pixel drag isn't a capture.
  selection.Begin({300, 200});
  selection.End({301, 201});
  assert(!selection.selected());
  selection.Reset(5000, 2600);
  selection.Begin({1800.5, 300.5});
  selection.End({2700.5, 2100.5});
  ExpectRect(selection, {1800.5, 300.5, 2700.5, 2100.5});
  selection.Reset(5000, 2600);
  assert(!selection.selected() && !selection.dragging());
  std::cout << "Screenshot selection checks passed\n";
}
