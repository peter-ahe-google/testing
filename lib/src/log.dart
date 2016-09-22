// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library testing.log;

/// ANSI escape code for moving cursor one line up.
/// See [CSI codes](https://en.wikipedia.org/wiki/ANSI_escape_code#CSI_codes).
const String cursorUp = "\u001b[1A";

/// ANSI escape code for erasing the entire line.
/// See [CSI codes](https://en.wikipedia.org/wiki/ANSI_escape_code#CSI_codes).
const String eraseLine = "\u001b[2K";

void logTestComplete(int completed, int failed, int total, {String suffix}) {
  suffix ??= "";
  String percent = pad((completed / total * 100.0).toStringAsFixed(1), 5);
  String good = pad(completed, 5);
  String bad = pad(failed, 5);
  print("$eraseLine[ $percent% | +$good | -$bad ]$suffix$cursorUp");
}

String pad(Object o, int pad) {
  String result = (" " * pad) + "$o";
  return result.substring(result.length - pad);
}
