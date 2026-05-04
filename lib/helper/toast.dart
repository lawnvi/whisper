import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';

void showAppToast(String message, {Toast? toastLength}) {
  unawaited(_showAppToast(message, toastLength: toastLength));
}

Future<void> _showAppToast(String message, {Toast? toastLength}) async {
  try {
    await Fluttertoast.showToast(msg: message, toastLength: toastLength);
  } on MissingPluginException {
    debugPrint('Toast unavailable: $message');
  }
}
