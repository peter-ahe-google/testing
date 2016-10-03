// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library testing.dart_vm_suite;

import 'dart:convert' show UTF8;
import 'dart:io' show Process;
import 'testing.dart';

Future<SuiteContext> createSuiteContext(Chain suite) async {
  return new VmContext();
}

class VmContext extends SuiteContext {
  final List<Step> steps = const <Step>[const DartVm()];
}

class DartVm extends Step<TestDescription, int, VmContext> {
  const DartVm();

  String get name => "Dart VM";

  Future<Result<int>> run(TestDescription input, VmContext context) async {
    Process process = await Process.start("dart", [input.file.path]);
    process.stdin.close();
    Future<List<String>> stdoutFuture =
        process.stdout.transform(UTF8.decoder).toList();
    Future<List<String>> stderrFuture =
        process.stderr.transform(UTF8.decoder).toList();
    int exitCode = await process.exitCode;
    StringBuffer sb = new StringBuffer();
    sb.writeAll(await stdoutFuture);
    sb.writeAll(await stderrFuture);
    if (exitCode == 0) {
      return new Result<int>.pass(exitCode);
    } else {
      return new Result<int>.fail(exitCode, "$sb");
    }
  }
}
