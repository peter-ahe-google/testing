// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library testing.run_tests;

import 'dart:async' show
    Future;

import 'dart:io' show
    File;

import 'dart:io' as io show
    exitCode;

import 'dart:isolate' show
    Isolate;

import 'error_handling.dart' show
    withErrorHandling;

import 'test_root.dart' show
    TestRoot;

import 'zone_helper.dart' show
    runGuarded;

import 'log.dart' show
    enableVerboseOutput,
    isVerbose,
    logMessage,
    logSuiteComplete,
    logTestComplete;

import 'run.dart' show
    SuiteRunner,
    runProgram;

class CommandLine {
  final Set<String> options;
  final List<String> arguments;

  CommandLine(this.options, this.arguments);

  bool get verbose => options.contains("--verbose") || options.contains("-v");

  Set<String> get skip {
    return options.expand((String s) {
      const String prefix = "--skip=";
      if (!s.startsWith(prefix)) return const [];
      s = s.substring(prefix.length);
      return s.split(",");
    }).toSet();
  }

  static CommandLine parse(List<String> arguments) {
    int index = arguments.indexOf("--");
    Set<String> options;
    if (index != -1) {
      options = new Set<String>.from(arguments.getRange(0, index - 1));
      arguments = arguments.sublist(index + 1);
    } else {
      options =
          arguments.where((argument) => argument.startsWith("-")).toSet();
      arguments =
          arguments.where((argument) => !argument.startsWith("-")).toList();
    }
    return new CommandLine(options, arguments);
  }
}

main(List<String> arguments) => withErrorHandling(() async {
  fail(String message) {
    print(message);
    io.exitCode = 1;
  }
  CommandLine cl = CommandLine.parse(arguments);
  if (cl.verbose) {
    enableVerboseOutput();
  }
  if (cl.arguments.length > 1) {
    return fail("Usage: run_tests.dart [configuration_file]");
  }
  String configurationPath = cl.arguments.length == 0
      ? "testing.json" : cl.arguments.first;
  logMessage("Reading configuration file '$configurationPath'.");
  Uri configuration =
      await Isolate.resolvePackageUri(Uri.base.resolve(configurationPath));
  if (configuration == null ||
      !await new File.fromUri(configuration).exists()) {
    return fail("Couldn't locate: '$configurationPath'.");
  }
  if (!isVerbose) {
    print("Use --verbose to display more details.");
  }
  TestRoot root = await TestRoot.fromUri(configuration);
  Set<String> skip = cl.skip;
  SuiteRunner runner = new SuiteRunner(
      root.suites.where((s) => !skip.contains(s.name)).toList());
  String program = await runner.generateDartProgram();
  await runner.analyze(root.packages);
  Stopwatch sw = new Stopwatch()..start();
  if (program == null) {
    fail("No tests configured.");
  } else {
    await runProgram(program, root.packages);
  }
  print("Running tests took: ${sw.elapsed}.");
});

Future<Null> runTests(Map<String, Function> tests) =>
withErrorHandling(() async {
  int completed = 0;
  for (String name in tests.keys) {
    StringBuffer sb = new StringBuffer();
    try {
      await runGuarded(() {
        print("Running test $name");
        return tests[name]();
      }, printLineOnStdout: sb.writeln);
      logMessage(sb);
    } catch (e) {
      print(sb);
      rethrow;
    }
    logTestComplete(++completed, 0, tests.length);
  }
  logSuiteComplete();
});
