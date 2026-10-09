/// Leave enough space for touch targets and the conversation composer.
bool usesSplitDeviceWorkspace({
  required double width,
  required bool desktop,
  required bool ios,
}) => desktop || (ios && width >= 840);

/// The physical display stays tablet-sized when Split View narrows the app.
bool usesRetainedTabletWorkspace({
  required bool ios,
  required double displayShortestSide,
}) => ios && displayShortestSide >= 600;
