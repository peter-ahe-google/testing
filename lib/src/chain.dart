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
    logStepComplete,
    logStepStart,
    logSuiteComplete,
    logTestComplete,
    logUnexpectedResult,
    splitLines;

import 'multitest.dart' show
    MultitestTransformer,
    isError;

typedef Future<ChainContext> CreateContext(
    Chain suite, Map<String, String> environment);

/// A test suite for tool chains, for example, a compiler.
class Chain extends Suite {
  final Uri source;

  final Uri uri;

  final List<RegExp> pattern;

  final List<RegExp> exclude;

  final bool processMultitests;

  Chain(String name, String kind, this.source, this.uri, Uri statusFile,
      this.pattern, this.exclude, this.processMultitests)
      : super(name, kind, statusFile);

  factory Chain.fromJsonMap(
      Uri base, Map json, String name, String kind) {
    Uri source = base.resolve(json["source"]);
    Uri uri = base.resolve(json["path"]);
    Uri statusFile = base.resolve(json["status"]);
    List<RegExp> pattern = new List<RegExp>.from(
        json["pattern"].map((String p) => new RegExp(p)));
    List<RegExp> exclude = new List<RegExp>.from(
        json["exclude"].map((String p) => new RegExp(p)));
    bool processMultitests = json["process-multitests"] ?? false;
    return new Chain(
        name, kind, source, uri, statusFile, pattern, exclude, processMultitests);
  }

  void writeImportOn(StringSink sink) {
    sink.write("import '");
    sink.write(source);
    sink.write("' as ");
    sink.write(name);
    sink.writeln(";");
  }

  void writeClosureOn(StringSink sink) {
    sink.write("await runChain(");
    sink.write(name);
    sink.writeln(".createContext, environment, selectors, r'''");
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
      "process-multitests": processMultitests,
      "pattern": []..addAll(pattern.map((RegExp r) => r.pattern)),
      "exclude": []..addAll(exclude.map((RegExp r) => r.pattern)),
    };
  }
}

abstract class ChainContext {
  const ChainContext();

  List<Step> get steps;

  Future<Null> run(Chain suite, Set<String> selectors) async {
    TestExpectations expectations = await ReadTestExpectations(
        <String>[suite.statusFile.toFilePath()], {});
    Stream<TestDescription> stream = list(suite);
    if (suite.processMultitests) {
      stream = stream.transform(new MultitestTransformer());
    }
    List<TestDescription> descriptions = await stream.toList();
    descriptions.sort();
    Map<TestDescription, Result> unexpectedResults =
        <TestDescription, Result>{};
    Map<TestDescription, Set<Expectation>> unexpectedOutcomes =
        <TestDescription, Set<Expectation>>{};
    int completed = 0;
    List<Future> futures = <Future>[];
    for (TestDescription description in descriptions) {
      String selector = "${suite.name}/${description.shortName}";
      if (selectors.isNotEmpty &&
          !selectors.contains(selector) &&
          !selectors.contains(suite.name)) {
        continue;
      }
      final Set<Expectation> expectedOutcomes =
          expectations.expectations(description.shortName);
      final StringBuffer sb = new StringBuffer();
      final Step lastStep = steps.isNotEmpty ? steps.last : null;
      final Iterator<Step> iterator = steps.iterator;

      Result result;
      // Records the outcome of the last step that was run.
      Step lastStepRun;

      /// Performs one step of [iterator].
      ///
      /// If `step.isAsync` is true, the corresponding step is said to be
      /// asynchronous.
      ///
      /// If a step is asynchrouns the future returned from this function will
      /// complete after the the first asynchronous step is scheduled.  This
      /// allows us to start processing the next test while an external process
      /// completes as steps can be interleaved. To ensure all steps are
      /// completed, wait for [futures].
      ///
      /// Otherwise, the future returned will complete when all steps are
      /// completed. This ensures that tests are run in sequence without
      /// interleaving steps.
      Future doStep(dynamic input) async {
        Future future;
        bool isAsync = false;
        if (iterator.moveNext()) {
          Step step = iterator.current;
          lastStepRun = step;
          isAsync = step.isAsync;
          logStepStart(completed, unexpectedResults.length, descriptions.length,
              suite, description, step);
          future = runGuarded(() async {
            try {
              return await step.run(input, this);
            } catch (error, trace) {
              return step.unhandledError(error, trace);
            }
          }, printLineOnStdout: sb.writeln);
        } else {
          future = new Future.value(null);
        }
        future = future.then((Result currentResult) {
          if (currentResult != null) {
            logStepComplete(completed, unexpectedResults.length,
                descriptions.length, suite, description, lastStepRun);
            result = currentResult;
            if (currentResult.outcome == Expectation.PASS) {
              // The input to the next step is the output of this step.
              return doStep(result.output);
            }
          }
          if (description.multitestExpectations != null) {
            if (isError(description.multitestExpectations)) {
              result = result.toNegativeTestResult();
            }
          } else if (lastStep == lastStepRun &&
              description.shortName.endsWith("negative_test")) {
            if (result.outcome == Expectation.PASS) {
              result.addLog("Negative test didn't report an error.\n");
            } else if (result.outcome == Expectation.FAIL) {
              result.addLog("Negative test reported an error as expeceted.\n");
            }
            result = result.toNegativeTestResult();
          }
          if (!expectedOutcomes.contains(result.outcome)) {
            result.addLog("$sb");
            unexpectedResults[description] = result;
            unexpectedOutcomes[description] = expectedOutcomes;
            logUnexpectedResult(suite, description, result, expectedOutcomes);
          } else {
            logMessage(sb);
          }
          logTestComplete(++completed, unexpectedResults.length,
              descriptions.length, suite, description);
        });
        if (isAsync) {
          futures.add(future);
          return null;
        } else {
          return future;
        }
      }
      // The input of the first step is [description].
      await doStep(description);
    }
    await Future.wait(futures);
    logSuiteComplete();
    if (unexpectedResults.isNotEmpty) {
      unexpectedResults.forEach((TestDescription description, Result result) {
        exitCode = 1;
        logUnexpectedResult(suite, description, result,
            unexpectedOutcomes[description]);
      });
      print("${unexpectedResults.length} failed:");
      unexpectedResults.forEach((TestDescription description, Result result) {
        print("${suite.name}/${description.shortName}: ${result.outcome}");
      });
    }
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

  bool get isAsync => false;

  bool get isCompiler => false;

  bool get isRuntime => false;

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

  Result<O> toNegativeTestResult() {
    Expectation outcome = this.outcome;
    if (outcome == Expectation.PASS) {
      outcome = Expectation.FAIL;
    } else if (outcome == Expectation.FAIL) {
      outcome = Expectation.PASS;
    }
    return new Result<O>(output, outcome, error, trace)
        ..logs.addAll(logs);
  }
}

/// This is called from generated code.
Future<Null> runChain(
    CreateContext f, Map<String, String> environment, Set<String> selectors,
    String json) {
  return withErrorHandling(() async {
    Chain suite = new Suite.fromJsonMap(Uri.base, JSON.decode(json));
    print("Running ${suite.name}");
    ChainContext context = await f(suite, environment);
    return context.run(suite, selectors);
  });
}
