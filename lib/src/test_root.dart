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
///         {
///           "name": "test",
///           # Root directory of tests in this suite.
///           "path": "test/",
///           # So far, only one kind of suite is recognized: `Dart
///           # (combined)`.
///           "kind": "Dart (combined)",
///           # Files in `path` that match any of the following regular
///           # expressions are considered to be part of this suite.
///           "pattern": [
///             "_test.dart$"
///           ],
///           # Except if they match any of the following regular expressions.
///           "exclude": [
///             "/golden/"
///           ]
///         }
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

  Iterable<Suite> get dartCombined {
    return suites.where((Suite suite) => suite.kind == "Dart (combined)");
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
class Suite {
  final String name;

  final Uri uri;

  final String kind;

  final List<RegExp> pattern;

  final List<RegExp> exclude;

  Suite(this.name, this.uri, this.kind, this.pattern, this.exclude);

  factory Suite.fromJsonMap(Uri base, Map json) {
    String name = json["name"];
    Uri uri = base.resolve(json["path"]);
    String kind = json["kind"];
    List<RegExp> pattern = new List<RegExp>.from(
        json["pattern"].map((String p) => new RegExp(p)));
    List<RegExp> exclude = new List<RegExp>.from(
        json["exclude"].map((String p) => new RegExp(p)));
    return new Suite(name, uri, kind, pattern, exclude);
  }

  String toString() => "Suite($name, $uri, $kind, $pattern, $exclude)";
}

main(List<String> arguments) async {
  for (String argument in arguments) {
    print(await TestRoot.fromUri(Uri.base.resolve(argument)));
  }
}
