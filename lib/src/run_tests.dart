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

import 'dart:isolate' show
    ReceivePort;

import '../testing.dart' show
    TestDescription,
    dartArguments,
    dartSdk,
    listTests,
    startDart;

import 'test_root.dart' show
    Compilation,
    DartCombined,
    TestRoot;

Stream<TestDescription> listRoots(TestRoot root) async* {
  for (DartCombined suite in root.dartCombined) {
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

main(List<String> arguments) async {
  final ReceivePort port = new ReceivePort();
  TestRoot testRoot =
      await TestRoot.fromUri(Uri.base.resolve(arguments.single));
  List<TestDescription> descriptions = await listRoots(testRoot).toList();
  descriptions.sort();
  List<Uri> urisToAnalyze = <Uri>[]
      ..addAll(testRoot.urisToAnalyze)
      ..addAll(
          descriptions.map((TestDescription description) => description.uri));
  await analyzeUris(
      testRoot.packages, urisToAnalyze, testRoot.excludedFromAnalysis);
  StringBuffer sb = new StringBuffer();
  sb.writeln("library testing.combined;\n");
  sb.writeln("import 'dart:async' show Future;\n");
  sb.writeln("import 'dart:io' show Directory;\n");
  sb.writeln("import 'package:testing/src/run_tests.dart' show runTests;\n");
  sb.writeln("import 'package:testing/src/compilation_runner.dart' show");
  sb.writeln("    runCompilationSuiteHelper;\n");
  for (TestDescription description in descriptions) {
    String shortName = description.shortName.replaceAll("/", "__");
    sb.writeln(
        "import '${description.uri}' as $shortName "
        "show main;");
  }
  for (Compilation suite in testRoot.compilation) {
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
  for (Compilation suite in testRoot.compilation) {
    sb.writeln("  await runCompilationSuiteHelper(");
    sb.writeln("      ${suite.name}.createSuiteContext,");
    sb.writeln("      r'${JSON.encode(suite)}');");
  }
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
Future<Null> analyzeUris(
    Uri packages, List<Uri> uris, List<RegExp> exclude) async {
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
  print("Running ${analyzer.toFilePath()} ${arguments.join(' ')}");
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
