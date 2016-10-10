// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library testing.log;

import 'chain.dart' show
    Result;

import 'test_description.dart' show
    TestDescription;

/// ANSI escape code for moving cursor one line up.
/// See [CSI codes](https://en.wikipedia.org/wiki/ANSI_escape_code#CSI_codes).
const String cursorUp = "\u001b[1A";

/// ANSI escape code for erasing the entire line.
/// See [CSI codes](https://en.wikipedia.org/wiki/ANSI_escape_code#CSI_codes).
const String eraseLine = "\u001b[2K";

const bool isVerbose = const bool.fromEnvironment("verbose");

void logTestComplete(int completed, int failed, int total, {String suffix}) {
  suffix ??= "";
  String percent = pad((completed / total * 100.0).toStringAsFixed(1), 5);
  String good = pad(completed, 5);
  String bad = pad(failed, 5);
  String message = "[ $percent% | +$good | -$bad ]$suffix";
  if (isVerbose) {
    print(message);
  } else {
    print("$eraseLine$message$cursorUp");
  }
}

void logMessage(Object message) {
  if (isVerbose) {
    print("$message");
  }
}

void logUnexpectedResult(TestDescription description, Result result) {
  print("${eraseLine}UNEXPECTED: ${description.shortName}");
  String log = result.log;
  if (log.isNotEmpty) {
    print(log);
  }
  print(result.error);
  if (result.trace != null) {
    print(result.trace);
  }
}

void logSuiteComplete() {
  if (!isVerbose) {
    print("");
  }
}

String pad(Object o, int pad) {
  String result = (" " * pad) + "$o";
  return result.substring(result.length - pad);
}
