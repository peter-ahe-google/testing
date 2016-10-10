// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library testing.run_tests;

import 'dart:async' show
    Stream,
    Future;

import 'dart:convert' show
    JSON,
    LineSplitter,
    UTF8;

import 'dart:io' show
    Directory,
    File,
    Process,
    stderr,
    stdout;

import 'dart:io' as io show
    exitCode;

import 'dart:isolate' show
    Isolate;

import '../testing.dart' show
    Chain,
    TestDescription,
    dartSdk,
    listTests,
    startDart;

import 'error_handling.dart' show
    withErrorHandling;

import 'suite.dart' show
    Dart;

import 'test_root.dart' show
    TestRoot;

import 'zone_helper.dart' show
    runGuarded;

import 'log.dart';

class CommandLine {
  final Set<String> options;
  final List<String> arguments;

  CommandLine(this.options, this.arguments);

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

Stream<TestDescription> listRoots(TestRoot root) async* {
  for (Dart suite in root.dartSuites) {
    await for (TestDescription description in
                   listTests(<Uri>[suite.uri], pattern: "")) {
      String path = description.file.uri.path;
      if (suite.exclude.any((RegExp r) => path.contains(r))) continue;
      if (suite.pattern.any((RegExp r) => path.contains(r))) {
        yield description;
      }
    }
  }
}

main(List<String> arguments) => withErrorHandling(() async {
  fail(String message) {
    print(message);
    io.exitCode = 1;
  }
  CommandLine cl = CommandLine.parse(arguments);
  final bool isVerbose =
      cl.options.contains("--verbose") || cl.options.contains("-v");
  if (cl.arguments.length > 1) {
    return fail("Usage: run_tests.dart [configuration_file]");
  }
  String configurationPath = cl.arguments.length == 0
      ? "testing.json" : cl.arguments.first;
  if (isVerbose) {
    print("Reading configuration file '$configurationPath'.");
  }
  Uri configuration =
      await Isolate.resolvePackageUri(Uri.base.resolve(configurationPath));
  if (configuration == null ||
      !await new File.fromUri(configuration).exists()) {
    return fail("Couldn't locate: '$configurationPath'.");
  }
  if (!isVerbose) {
    print("Use --verbose to display more details.");
  }
  TestRoot testRoot = await TestRoot.fromUri(configuration);
  List<TestDescription> descriptions = await listRoots(testRoot).toList();
  descriptions.sort();
  List<Uri> urisToAnalyze = <Uri>[]
      ..addAll(testRoot.urisToAnalyze)
      ..addAll(
          descriptions.map((TestDescription description) => description.uri));
  await analyzeUris(testRoot.packages, urisToAnalyze,
      testRoot.excludedFromAnalysis, isVerbose: isVerbose);
  StringBuffer sb = new StringBuffer();
  bool hasTests = false;
  sb.writeln("library testing.generated;\n");
  sb.writeln("import 'dart:async' show Future;\n");
  sb.writeln("import 'dart:io' show Directory;\n");
  sb.writeln("import 'package:testing/src/run_tests.dart' show runTests;\n");
  sb.writeln("import 'package:testing/src/chain.dart' show");
  sb.writeln("    runChain;\n");
  for (TestDescription description in descriptions) {
    hasTests = true;
    String shortName = description.shortName.replaceAll("/", "__");
    sb.writeln(
        "import '${description.uri}' as $shortName "
        "show main;");
  }
  for (Chain suite in testRoot.toolChains) {
    hasTests = true;
    sb.writeln("import '${suite.source}' as ${suite.name};");
  }
  sb.writeln("\nFuture<Null> main() async {");
  sb.writeln("  await runTests(<String, Function> {");
  for (TestDescription description in descriptions) {
    String shortName = description.shortName.replaceAll("/", "__");
    sb.writeln(
        '    "$shortName": $shortName.main,');
  }
  sb.writeln("  });");
  for (Chain suite in testRoot.toolChains) {
    sb.writeln("  await runChain(");
    sb.writeln("      ${suite.name}.createContext,");
    sb.writeln("      r'${JSON.encode(suite)}');");
  }
  sb.write("}");

  if (!hasTests) {
    return fail("No tests configured.");
  }

  Stopwatch sw = new Stopwatch()..start();
  Directory tmp = await Directory.systemTemp.createTemp();
  try {
    File generated = new File.fromUri(tmp.uri.resolve("generated.dart"));
    await generated.writeAsString("$sb", flush: true);
    if (isVerbose) {
      print("==> ${generated.path} <==");
      print(numberedLines('$sb'));
    } else {
      print("Running ${generated.path}.");
    }
    Process process = await startDart(
        generated.uri, null,
        <String>[
            "-c", "-Dverbose=$isVerbose",
            "--packages=${testRoot.packages.toFilePath()}"]);
    process.stdin.close();
    Future stdoutFuture =
        process.stdout.listen((data) => stdout.add(data)).asFuture();
    Future stderrFuture =
        process.stderr.listen((data) => stderr.add(data)).asFuture();
    int exitCode = await process.exitCode;
    await stdoutFuture;
    await stderrFuture;
    if (exitCode != 0) {
      throw "non-zero exit code ($exitCode) from ${generated.path}";
    }
  } finally {
    tmp.delete(recursive: true);
  }
  sw.stop();
  print("Running tests took: ${sw.elapsed}.");
});

class AnalyzerDiagnostic {
  final String kind;

  final String detailedKind;

  final String code;

  final Uri uri;

  final int line;

  final int startColumn;

  final int endColumn;

  final String message;

  AnalyzerDiagnostic(this.kind, this.detailedKind, this.code, this.uri,
      this.line, this.startColumn, this.endColumn, this.message);

  factory AnalyzerDiagnostic.fromLine(String line) {
    List<String> parts = line.split("|");
    if (parts.length != 8) {
      throw "Malformed output: $line";
    }
    return new AnalyzerDiagnostic(parts[0], parts[1], parts[2],
        Uri.base.resolve(parts[3]),
        int.parse(parts[4]), int.parse(parts[5]), int.parse(parts[6]),
        parts[7]);
  }

  String toString() {
    return "$uri:$line:$startColumn: "
        "${kind == 'INFO' ? 'warning: hint' : kind.toLowerCase()}:\n$message";
  }
}

Stream<AnalyzerDiagnostic> parseAnalyzerOutput(
    Stream<List<int>> stream) async* {
  Stream<String> lines =
      stream.transform(UTF8.decoder).transform(new LineSplitter());
  await for (String line in lines) {
    yield new AnalyzerDiagnostic.fromLine(line);
  }
}

/// Run dartanalyzer on all tests in [uris].
Future<Null> analyzeUris(Uri packages, List<Uri> uris, List<RegExp> exclude,
    {bool isVerbose: false}) async {
  if (uris.isEmpty) return;
  const String analyzerPath = "bin/dartanalyzer";
  Uri analyzer = dartSdk.resolve(analyzerPath);
  if (!await new File.fromUri(analyzer).exists()) {
    throw "Couldn't find '$analyzerPath' in '${dartSdk.toFilePath()}'";
  }
  List<String> arguments = <String>[
      "--packages=${packages.toFilePath()}",
      "--package-warnings",
      "--format=machine",
  ];
  arguments.addAll(uris.map((Uri uri) => uri.toFilePath()));
  if (isVerbose) {
    print("Running ${analyzer.toFilePath()} ${arguments.join(' ')}.");
  } else {
    print("Running dartanalyzer.");
  }
  Stopwatch sw = new Stopwatch()..start();
  Process process = await Process.start(analyzer.toFilePath(), arguments);
  process.stdin.close();
  Future stdoutFuture = parseAnalyzerOutput(process.stdout).toList();
  Future stderrFuture = parseAnalyzerOutput(process.stderr).toList();
  await process.exitCode;
  List<AnalyzerDiagnostic> diagnostics = <AnalyzerDiagnostic>[];
  diagnostics.addAll(await stdoutFuture);
  diagnostics.addAll(await stderrFuture);
  bool hasOutput = false;
  for (AnalyzerDiagnostic diagnostic in diagnostics) {
    String path = diagnostic.uri.path;
    if (exclude.any((RegExp r) => path.contains(r))) continue;
    hasOutput = true;
    print(diagnostic);
  }
  if (hasOutput) {
    throw "Non-empty output from analyzer.";
  }
  sw.stop();
  print("Running analyzer took: ${sw.elapsed}.");
}

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

String numberedLines(String text) {
  StringBuffer result = new StringBuffer();
  int lineNumber = 1;
  List<String> lines = splitLines(text);
  int pad = "${lines.length}".length;
  String fill = " " * pad;
  for (String line in lines) {
    String paddedLineNumber = "$fill$lineNumber";
    paddedLineNumber =
        paddedLineNumber.substring(paddedLineNumber.length - pad);
    result.write("$paddedLineNumber: $line");
    lineNumber++;
  }
  return '$result';
}

List<String> splitLines(String text) {
  return text.split(new RegExp('^', multiLine: true));
}
