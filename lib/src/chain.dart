// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library testing.chain;

import 'dart:async' show
    Future,
    Stream;

import 'dart:convert' show
    JSON,
    JsonEncoder;

import 'dart:io' show
    Directory,
    File,
    FileSystemEntity,
    exitCode;

import 'suite.dart' show
    Suite;

import '../testing.dart' show
    TestDescription;

import 'test_dart/status_file_parser.dart' show
    Expectation,
    ReadTestExpectations,
    TestExpectations;

import 'zone_helper.dart' show
    runGuarded;

import 'error_handling.dart' show
    withErrorHandling;

import 'log.dart' show
    logMessage,
    logSuiteComplete,
    logTestComplete,
    logUnexpectedResult,
    splitLines;

typedef Future<ChainContext> CreateContext(
    Chain suite, Map<String, String> environment);

/// A test suite for tool chains, for example, a compiler.
class Chain extends Suite {
  final Uri source;

  final Uri uri;

  final Uri statusFile;

  final List<RegExp> pattern;

  final List<RegExp> exclude;

  Chain(String name, String kind, this.source, this.uri, this.statusFile,
      this.pattern, this.exclude)
      : super(name, kind);

  factory Chain.fromJsonMap(
      Uri base, Map json, String name, String kind) {
    Uri source = base.resolve(json["source"]);
    Uri uri = base.resolve(json["path"]);
    Uri statusFile = base.resolve(json["status"]);
    List<RegExp> pattern = new List<RegExp>.from(
        json["pattern"].map((String p) => new RegExp(p)));
    List<RegExp> exclude = new List<RegExp>.from(
        json["exclude"].map((String p) => new RegExp(p)));
    return new Chain(
        name, kind, source, uri, statusFile, pattern, exclude);
  }

  void writeImportOn(StringSink sink) {
    sink.write("import '");
    sink.write(source);
    sink.write("' as ");
    sink.write(name);
    sink.writeln(";");
  }

  void writeClosureOn(StringSink sink) {
    sink.write("runChain(");
    sink.write(name);
    sink.writeln(".createContext, environment, r'''");
    const String jsonExtraIndent = "    ";
    sink.write(jsonExtraIndent);
    sink.writeAll(splitLines(new JsonEncoder.withIndent("  ").convert(this)),
        jsonExtraIndent);
    sink.writeln("''');");
  }

  Map toJson() {
    return {
      "name": name,
      "kind": kind,
      "source": "$source",
      "path": "$uri",
      "status": "$statusFile",
      "pattern": []..addAll(pattern.map((RegExp r) => r.pattern)),
      "exclude": []..addAll(exclude.map((RegExp r) => r.pattern)),
    };
  }
}

abstract class ChainContext {
  const ChainContext();

  List<Step> get steps;

  Future<Null> run(Chain suite) async {
    TestExpectations expectations = await ReadTestExpectations(
        <String>[suite.statusFile.toFilePath()], {});
    List<TestDescription> descriptions = await list(suite).toList();
    descriptions.sort();
    Map<TestDescription, Result> unexpectedResults =
        <TestDescription, Result>{};
    int completed = 0;
    for (TestDescription description in descriptions) {
      Set<Expectation> expectedOutcomes =
          expectations.expectations(description.shortName);
      Result result;
      // The input of the first step is [description]. The input to step n+1 is
      // the output of step n.
      dynamic input = description;
      StringBuffer sb = new StringBuffer();
      bool hasUnexpectedResult = false;
      for (Step step in steps) {
        result = await runGuarded(() async {
          print("Running ${step.name}.");
          try {
            return await step.run(input, this);
          } catch (error, trace) {
            return step.unhandledError(error, trace);
          }
        }, printLineOnStdout: sb.writeln);
        if (result.outcome == Expectation.PASS) {
          input = result.output;
        } else {
          if (!expectedOutcomes.contains(result.outcome)) {
            hasUnexpectedResult = true;
            result.addLog("$sb");
            unexpectedResults[description] = result;
            logUnexpectedResult(description, result);
          }
          break;
        }
      }
      if (!hasUnexpectedResult) {
        logMessage(sb);
      }
      logTestComplete(++completed, unexpectedResults.length,
          descriptions.length,
          suffix: ": ${suite.name}/${description.shortName}");
    }
    logSuiteComplete();
    unexpectedResults.forEach((TestDescription description, Result result) {
      exitCode = 1;
      logUnexpectedResult(description, result);
    });
  }

  Stream<TestDescription> list(Chain suite) async* {
    Directory testRoot = new Directory.fromUri(suite.uri);
    if (await testRoot.exists()) {
      Stream<FileSystemEntity> files =
          testRoot.list(recursive: true, followLinks: false);
      await for (FileSystemEntity entity in files) {
        if (entity is! File) continue;
        String path = entity.uri.path;
        if (suite.exclude.any((RegExp r) => path.contains(r))) continue;
        if (suite.pattern.any((RegExp r) => path.contains(r))) {
          yield new TestDescription(suite.uri, entity);
        }
      }
    } else {
      throw "${suite.uri} isn't a directory";
    }
  }
}

abstract class Step<I, O, C extends ChainContext> {
  const Step();

  String get name;

  Future<Result<O>> run(I input, C context);

  Result<O> unhandledError(error, StackTrace trace) {
    return new Result<O>.crash(error, trace);
  }

  Result<O> pass(O output) => new Result<O>.pass(output);

  Result<O> crash(error, StackTrace trace) => new Result<O>.crash(error, trace);

  Result<O> fail(O output, [error, StackTrace trace]) {
    return new Result<O>.fail(output, error, trace);
  }
}

class Result<O> {
  final O output;

  final Expectation outcome;

  final error;

  final StackTrace trace;

  final List<String> logs = <String>[];

  Result(this.output, this.outcome, this.error, this.trace);

  Result.pass(O output)
      : this(output, Expectation.PASS, null, null);

  Result.crash(error, StackTrace trace)
      : this(null, Expectation.CRASH, error, trace);

  Result.fail(O output, [error, StackTrace trace])
      : this(output, Expectation.FAIL, error, trace);

  String get log => logs.join();

  void addLog(String log) {
    logs.add(log);
  }
}

/// This is called from generated code.
Future<Null> runChain(
    CreateContext f, Map<String, String> environment, String json) {
  return withErrorHandling(() async {
    Chain suite = new Suite.fromJsonMap(Uri.base, JSON.decode(json));
    print("Running ${suite.name}");
    ChainContext context = await f(suite, environment);
    return context.run(suite);
  });
}
