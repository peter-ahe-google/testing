// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library testing.run_tests;

import 'dart:async' show
    Future;

import 'dart:io' show
    Directory,
    File,
    FileSystemEntity;

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

  Map<String, String> get environment {
    Map<String, String> result = <String, String>{};
    for (String option in options) {
      if (option.startsWith("-D")) {
        int equalIndex = option.indexOf("=");
        if (equalIndex != -1) {
          String key = option.substring(2, equalIndex);
          String value = option.substring(equalIndex + 1);
          result[key] = value;
        }
      }
    }
    return result;
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
  Map<String, String> environment = cl.environment;
  String configurationPath = cl.arguments.length == 0
      ? null : cl.arguments.first;
  if (configurationPath == null) {
    configurationPath = "testing.json";
    if (!await new File(configurationPath).exists()) {
      Directory test = new Directory("test");
      if (await test.exists()) {
        List<FileSystemEntity> candiates =
            await test.list(recursive: true, followLinks: false)
            .where((FileSystemEntity entity) {
              return entity is File &&
                  entity.uri.path.endsWith("/testing.json");
            }).toList();
        switch (candiates.length) {
          case 0:
            return fail("Couldn't locate: '$configurationPath'.");

          case 1:
            configurationPath = candiates.single.path;
            break;

          default:
            return fail("Usage: run_tests.dart [configuration_file]\n"
                "Where configuration_file is one of:\n  "
                "${candiates.map((File file) => file.path).join('\n  ')}");
        }
      }
    }
  }
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
  SuiteRunner runner = new SuiteRunner(environment,
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
