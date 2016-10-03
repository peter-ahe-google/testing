// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library testing.test_root;

import 'dart:async' show
    Future;

import 'dart:convert' show
    JSON;

import 'dart:io' show
    File;

import 'dart:isolate' show
    Isolate;

/// Records properties of a test root. The information is read from a JSON file.
///
/// Example with comments:
///     {
///       # Path to the `.packages` file used.
///       "packages": "test/.packages",
///       # A list of test suites (collection of tests).
///       "suites": [
///         # A list of suite objects. See the subclasses of [Suite] below.
///       ],
///       "analyze": {
///         # Uris to analyze.
///         "uris": [
///           "lib/",
///           "bin/dartk.dart",
///           "bin/repl.dart",
///           "test/log_analyzer.dart",
///           "third_party/testing/lib/"
///         ],
///         # Regular expressions of file names to ignore when analyzing.
///         "exclude": [
///           "/third_party/dart-sdk/pkg/compiler/",
///           "/third_party/kernel/"
///         ]
///       }
///     }
class TestRoot {
  final Uri packages;

  final List<Suite> suites;

  final List<Uri> urisToAnalyze;

  final List<RegExp> excludedFromAnalysis;

  TestRoot(this.packages, this.suites, this.urisToAnalyze,
      this.excludedFromAnalysis);

  Iterable<DartCombined> get dartCombined {
    return new List<DartCombined>.from(
        suites.where((Suite suite) => suite is DartCombined));
  }

  Iterable<Compilation> get compilation {
    return new List<Compilation>.from(
        suites.where((Suite suite) => suite is Compilation));
  }

  String toString() {
    return "TestRoot($suites, $urisToAnalyze)";
  }

  static Future<TestRoot> fromUri(Uri uri) async {
    String json = await new File.fromUri(uri).readAsString();
    Map data = JSON.decode(json);

    addDefaults(data);

    Uri packages = uri.resolve(data["packages"]);

    List<Suite> suites = new List<Suite>.from(
        data["suites"].map((Map json) => new Suite.fromJsonMap(uri, json)));

    List<Uri> urisToAnalyze = new List<Uri>.from(data["analyze"]["uris"]
        .map((String relative) => uri.resolve(relative)));

    // Also analyze the sources of any Compilation suites.
    urisToAnalyze.addAll(suites
        .where((Suite suite) => suite is Compilation)
        .map((Compilation suite) => suite.source));

    for (int i = 0; i < urisToAnalyze.length; i++) {
      urisToAnalyze[i] = await Isolate.resolvePackageUri(urisToAnalyze[i]);
    }
    List<RegExp> excludedFromAnalysis = new List<RegExp>.from(
        data["analyze"]["exclude"].map((String p) => new RegExp(p)));

    return new TestRoot(packages, suites, urisToAnalyze, excludedFromAnalysis);
  }

  static void addDefaults(Map data) {
    data.putIfAbsent("packages", () => ".packages");
    data.putIfAbsent("suites", () => []);
    Map analyze = data.putIfAbsent("analyze", () => {});
    analyze.putIfAbsent("uris", () => []);
    analyze.putIfAbsent("exclude", () => []);
  }
}

/// Records the properties of a test suite.
abstract class Suite {
  final String name;

  final String kind;

  Suite(this.name, this.kind);

  factory Suite.fromJsonMap(Uri base, Map json) {
    String kind = json["kind"].toLowerCase();
    String name = json["name"];
    switch (kind) {
      case "dart":
      case "dart (combined)": // TODO(ahe): Remove this case.
        return new DartCombined.fromJsonMap(base, json, name, kind);

      case "chain":
      case "compilation": // TODO(ahe): Remove this case.
        return new Compilation.fromJsonMap(base, json, name, kind);

      default:
        throw "Suite '$name' has unknown kind '$kind'.";
    }
  }

  String toString() => "Suite($name, $kind)";
}

/// A suite of standalone tests. The tests are combined and run as one program.
///
/// A standalone test is a test with a `main` method. The test is considered
/// successful if main doesn't throw an error (or if `main` returns a future,
/// that future completes without errors).
///
/// The tests are combined by generating a Dart file which imports all the main
/// methods and calls them sequentially.
///
/// Example JSON configuration:
///
///     {
///       "name": "test",
///       "kind": "Dart (combined)",
///       # Root directory of tests in this suite.
///       "path": "test/",
///       # Files in `path` that match any of the following regular expressions
///       # are considered to be part of this suite.
///       "pattern": [
///         "_test.dart$"
///       ],
///       # Except if they match any of the following regular expressions.
///       "exclude": [
///         "/golden/"
///       ]
///     }
class DartCombined extends Suite {
  final Uri uri;

  final List<RegExp> pattern;

  final List<RegExp> exclude;

  DartCombined(String name, String kind, this.uri, this.pattern, this.exclude)
      : super(name, kind);

  factory DartCombined.fromJsonMap(
      Uri base, Map json, String name, String kind) {
    Uri uri = base.resolve(json["path"]);
    List<RegExp> pattern = new List<RegExp>.from(
        json["pattern"].map((String p) => new RegExp(p)));
    List<RegExp> exclude = new List<RegExp>.from(
        json["exclude"].map((String p) => new RegExp(p)));
    return new DartCombined(name, kind, uri, pattern, exclude);
  }

  String toString() => "DartCombined($name, $uri, $pattern, $exclude)";
}

abstract class Chain implements Suite {
  Uri get source;

  Uri get uri;

  Uri get statusFile;

  List<RegExp> get pattern;

  List<RegExp> get exclude;

  Map toJson();
}

// TODO(ahe): Rename [Compilation] to [Chain].
class Compilation extends Suite implements Chain {
  final Uri source;

  final Uri uri;

  final Uri statusFile;

  final List<RegExp> pattern;

  final List<RegExp> exclude;

  Compilation(String name, String kind, this.source, this.uri, this.statusFile,
      this.pattern, this.exclude)
      : super(name, kind);

  factory Compilation.fromJsonMap(
      Uri base, Map json, String name, String kind) {
    Uri source = base.resolve(json["source"]);
    Uri uri = base.resolve(json["path"]);
    Uri statusFile = base.resolve(json["status"]);
    List<RegExp> pattern = new List<RegExp>.from(
        json["pattern"].map((String p) => new RegExp(p)));
    List<RegExp> exclude = new List<RegExp>.from(
        json["exclude"].map((String p) => new RegExp(p)));
    return new Compilation(
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
