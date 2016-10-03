// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library testing.compilation_runner;

import 'dart:async' show
    Future,
    Stream;

import 'dart:convert' show
    JSON;

import 'dart:io' show
    Directory,
    File,
    FileSystemEntity,
    exitCode;

import 'test_root.dart' show
    Compilation,
    Suite;

import '../testing.dart' show
    TestDescription;

import 'test_dart/status_file_parser.dart' show
    Expectation,
    ReadTestExpectations,
    TestExpectations;

import 'zone_helper.dart' show
    runGuarded;

import 'log.dart';

typedef Future<SuiteContext> CreateSuiteContext(Compilation);

abstract class SuiteContext {
  const SuiteContext();

  List<Step> get steps;

  Future<Null> run(Compilation suite) async {
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
      for (Step step in steps) {
        result = await runGuarded(() {
          print("Running ${step.name}.");
          return step.run(input, this);
        }, printLineOnStdout: sb.writeln);
        if (result.outcome == Expectation.PASS) {
          input = result.output;
        } else {
          if (!expectedOutcomes.contains(result.outcome)) {
            if (!isVerbose) {
              print(sb);
            }
            unexpectedResults[description] = result;
          }
          break;
        }
      }
      logMessage(sb);
      logTestComplete(++completed, unexpectedResults.length,
          descriptions.length, suffix: ": ${suite.name}");
    }
    logSuiteComplete();
    unexpectedResults.forEach((TestDescription description, Result result) {
      exitCode = 1;
      print("FAILED: ${description.shortName}");
      print(result.error);
      if (result.trace != null) {
        print(result.trace);
      }
    });
  }

  Stream<TestDescription> list(Compilation suite) async* {
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

/// This is called from generated code.
Future<Null> runCompilation(CreateSuiteContext f, String json) async {
  Compilation suite = new Suite.fromJsonMap(Uri.base, JSON.decode(json));
  print("Running ${suite.name}");
  SuiteContext context = await f(suite);
  return context.run(suite);
}
