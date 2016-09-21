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
        suites.where((Suite suite) => suite.kind == "Dart (combined)"));
  }

  String toString() {
    return "TestRoot($suites, $urisToAnalyze)";
  }

  static Future<TestRoot> fromUri(Uri uri) async {
    String json = await new File.fromUri(uri).readAsString();
    Map data = JSON.decode(json);

    Uri packages = uri.resolve(data["packages"]);

    List<Suite> suites = new List<Suite>.from(
        data["suites"].map((Map json) => new Suite.fromJsonMap(uri, json)));

    List<Uri> urisToAnalyze = new List<Uri>.from(data["analyze"]["uris"]
        .map((String relative) => uri.resolve(relative)));

    List<RegExp> excludedFromAnalysis = new List<RegExp>.from(
        data["analyze"]["exclude"].map((String p) => new RegExp(p)));

    return new TestRoot(packages, suites, urisToAnalyze, excludedFromAnalysis);
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
      case "dart (combined)":
        return new DartCombined.fromJsonMap(base, json, name, kind);

      case "compilation":
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

class Compilation extends Suite {
  final Uri uri = Uri.base.resolve("test/golden/");

  final Uri statusFile = Uri.base.resolve("test/reify.status");

  final List<RegExp> pattern = <RegExp>[new RegExp(r"\.dart$")];

  final List<RegExp> exclude = <RegExp>[];

  Compilation(String name, String kind)
      : super(name, kind);

  factory Compilation.fromJsonMap(
      Uri base, Map json, String name, String kind) {
    // TODO(ahe): Initialize above field with values from [json].
    return new Compilation(name, kind);
  }
}
