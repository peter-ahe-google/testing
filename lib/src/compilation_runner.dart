// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library testing.compilation_runner;

import 'dart:async' show
    Future,
    Stream;

import 'dart:io' show
    exitCode;

import 'test_root.dart' show
    Compilation;

import '../testing.dart' show
    TestDescription,
    listTests;

import 'test_dart/status_file_parser.dart' show
    Expectation,
    ReadTestExpectations,
    TestExpectations;

abstract class SuiteContext {
  const SuiteContext();

  List<Step> get steps;
}

abstract class Step<I, O, C extends SuiteContext> {
  const Step();

  String get name;

  Future<Result<O>> run(I input, C context);
}

class Result<O> {
  final O output;

  final Expectation outcome;

  final error;

  final StackTrace trace;

  Result(this.output, this.outcome, this.error, this.trace);

  Result.pass(O output)
      : this(output, Expectation.PASS, null, null);

  Result.crash(error, StackTrace trace)
      : this(null, Expectation.CRASH, error, trace);

  Result.fail(O output, [error, StackTrace trace])
      : this(output, Expectation.FAIL, error, trace);
}

Stream<TestDescription> listCompilationTests(Compilation compilation) async* {
  await for (TestDescription description in
                 listTests(<Uri>[compilation.uri], pattern: "")) {
    String path = description.file.uri.path;
    if (compilation.exclude.any((RegExp r) => path.contains(r))) continue;
    if (compilation.pattern.any((RegExp r) => path.contains(r))) {
      yield description;
    }
  }
}

Future<Null> runCompilationSuite(
    Compilation suite, SuiteContext context) async {
  TestExpectations expectations = await ReadTestExpectations(
      <String>[suite.statusFile.toFilePath()], {});
  List<TestDescription> descriptions =
      await listCompilationTests(suite).toList();
  descriptions.sort();
  Map<TestDescription, Result> unexpectedResults = <TestDescription, Result>{};
  Uri statusFileDir = suite.statusFile.resolve(".");
  for (TestDescription description in descriptions) {
    Set<Expectation> expectedOutcomes =
        expectations.expectations(description.shortName);
    Result result;
    var input = description;
    for (Step step in context.steps) {
      print("Running ${step.name}.");
      result = await step.run(input, context);
      if (result.outcome == Expectation.PASS) {
        input = result.output;
      } else {
        if (!expectedOutcomes.contains(result.outcome)) {
          unexpectedResults[description] = result;
        }
        break;
      }
    }
  }

  unexpectedResults.forEach((TestDescription description, Result result) {
    exitCode = 1;
    print("FAILED: ${description.shortName}");
    print(result.error);
  });
}
