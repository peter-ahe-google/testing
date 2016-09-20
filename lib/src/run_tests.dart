// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library rasta.testa;

import 'dart:io' show
    Directory,
    File,
    Platform,
    Process,
    stderr,
    stdout;

import 'dart:isolate' show
    ReceivePort;

import 'dart:async' show
    Future;

import 'package:rasta/testing.dart' show
    TestDescription,
    dartArguments,
    dartSdk,
    listTests,
    startDart;

main() async {
  final ReceivePort port = new ReceivePort();
  List<TestDescription> descriptions =
      await listTests(<Uri>[Platform.script.resolve(".")]).toList();
  descriptions.sort();
  List<TestDescription> unitTests = <TestDescription>[];
  List<TestDescription> goldenTests = <TestDescription>[];
  for (TestDescription description in descriptions) {
    if (description.uri.path.contains("/golden/")) {
      goldenTests.add(description);
    } else {
      unitTests.add(description);
    }
  }
  await analyzeTests(unitTests);
  StringBuffer sb = new StringBuffer();
  sb.writeln("library testa_combined;\n");
  sb.writeln("import '${Platform.script.path}' show runTests;\n");
  for (TestDescription description in unitTests) {
    String shortName = description.shortName.replaceAll("/", "__");
    sb.writeln(
        "import '${description.uri.path}' as $shortName "
        "show main;");
  }
  sb.writeln("\nvoid main() {");
  sb.writeln("  runTests(<String, Function> {");
  for (TestDescription description in unitTests) {
    String shortName = description.shortName.replaceAll("/", "__");
    sb.writeln(
        '    "$shortName": $shortName.main,');
  }
  sb.writeln("  });");
  sb.write("}");

  Stopwatch sw = new Stopwatch()..start();
  Directory tmp = await Directory.systemTemp.createTemp();
  try {
    File generated = new File.fromUri(tmp.uri.resolve("generated.dart"));
    await generated.writeAsString("$sb", flush: true);
    print("==> ${generated.path} <==");
    print(numberedLines('$sb'));
    Process process = await startDart(
        generated.uri, null,
        <String>["-Dverbose=false"]..addAll(dartArguments));
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
  print("Running tests took: ${sw.elapsed}");
  port.close();
}

/// Run dartanalyzer on all tests in [descriptions],
/// "../lib/reify_transformer.dart", and this script.
Future<Null> analyzeTests(List<TestDescription> descriptions) async {
  const String analyzerPath = "bin/dartanalyzer";
  Uri analyzer = dartSdk.resolve(analyzerPath);
  if (!await new File.fromUri(analyzer).exists()) {
    throw "Couldn't find '$analyzerPath' in '${dartSdk.toFilePath()}'";
  }
  List<String> arguments = new List<String>.from(
      descriptions.map(
          (TestDescription desciption) => desciption.uri.toFilePath()));
  arguments
      ..add(Platform.script.resolve("../lib/reify_transformer.dart")
            .toFilePath())
      ..add(Platform.script.resolve("../bin/dartk.dart")
            .toFilePath())
      ..add(Platform.script.resolve("../bin/repl.dart")
            .toFilePath())
      ..add(Platform.script.toFilePath());
  print("Running analyzer");
  Stopwatch sw = new Stopwatch()..start();
  Process process = await Process.start(
      "./run_analyzer.sh", arguments,
      environment: {"DART_SDK": dartSdk.toFilePath()});
  process.stdin.close();
  bool hasStdout = false;
  bool hasStderr = false;
  Future stdoutFuture = process.stdout.listen((data) {
    stdout.add(data);
    hasStdout = true;
  }).asFuture();
  Future stderrFuture = process.stderr.listen((data) {
    stderr.add(data);
    hasStderr = true;
  }).asFuture();
  int exitCode = await process.exitCode;
  await stdoutFuture;
  await stderrFuture;
  if (exitCode != 0) {
    throw "Non-zero exit code ($exitCode) from analyzer.";
  }
  if (hasStdout || hasStderr) {
    throw "Non-empty output from analyzer.";
  }
  sw.stop();
  print("Running analyzer took: ${sw.elapsed}");
}

Future<Null> runTests(Map<String, Function> tests) async {
  final ReceivePort port = new ReceivePort();
  for (String name in tests.keys) {
    print("Running test $name");
    await tests[name]();
  }
  port.close();
}

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
