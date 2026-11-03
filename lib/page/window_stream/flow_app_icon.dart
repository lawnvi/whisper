import 'package:flutter/material.dart';

import 'flow_space_theme.dart';

/// Stable colour for an app without an icon, so its monogram and recents
/// card keep the same hue everywhere.
Color flowAppHue(String appId, Brightness brightness) =>
    FlowSpaceTokens.deviceHue('app:$appId', brightness);
