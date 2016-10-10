// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library testing.chain;

import 'dart:async' show
    Future,
    Stream;

import 'dart:convert' show
    JSON;

import 'dart:io' show
    Directory,
    File,
    FileSystemEntity,
    Platform,
    exitCode;

import 'dart:isolate' show
    ReceivePort;

import 'suite.dart' show
    Suite;

import '../testing.dart' show
    TestDescription;

import 'test_root.dart' show
    TestRoot;

import 'test_dart/status_file_parser.dart' show
    Expectation,
    ReadTestExpectations,
    TestExpectations;

import 'zone_helper.dart' show
    runGuarded;

import 'log.dart';

typedef Future<ChainContext> CreateContext(Chain);

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
        result = await runGuarded(() {
          print("Running ${step.name}.");
          return step.run(input, this);
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
          descriptions.length, suffix: ": ${suite.name}");
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
Future<Null> runChain(CreateContext f, String json) async {
  Chain suite = new Suite.fromJsonMap(Uri.base, JSON.decode(json));
  print("Running ${suite.name}");
  ChainContext context = await f(suite);
  return context.run(suite);
}

Future<Null> runMe(
    List<String> arguments, CreateContext f, [String configurationPath]) async {
  final ReceivePort port = new ReceivePort();
  try {
    Uri configuration = configurationPath == null
        ? Uri.base.resolve("testing.json")
        : Platform.script.resolve(configurationPath);
    TestRoot testRoot = await TestRoot.fromUri(configuration);
    for (Chain suite in testRoot.toolChains) {
      if (Platform.script == suite.source) {
        print("Running suite ${suite.name}...");
        ChainContext context = await f(suite);
        await context.run(suite);
      }
    }
  } finally {
    port.close();
  }
}
