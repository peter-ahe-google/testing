<!--
Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
for details. All rights reserved. Use of this source code is governed by a
BSD-style license that can be found in the LICENSE file.
-->
# Test Infrastructure without the Batteries

This package:

  * Provides a way to run standalone tests. A standalone test is a test that has a `main` method, and can be run as a standalone program.

  * Provides a way to test a compiler in multiple steps.

  * Ensures all tests and implementation is free from warnings (using dartanalyzer).

## Configuration

The test runner is configured using a JSON file. A minimal configuration file is:

```json
{
}
```
### Test Suites

A test suite is a collection of tests. Currently, we support two categories of test suites:

  1. `Compilation`
  2. `Dart (combined)`

#### Compilation

A `Compilation` suite is a suite that's designed to test an AOT compiler or a JIT VM. However, it can be used to test anything that can be divided into one or more steps.

Here a complete example of a `Compilation` suite:

```json
{
  "suites": [
    {
      "name": "golden",
      "kind": "Compilation",
      "source": "test/golden_suite.dart",
      "path": "test/golden/",
      "status": "test/golden.status",
      "pattern": [
        "\\.dart$"
      ],
      "exclude": [
      ]
    }
  ]
}
```

The properties of a `Compilation` suite are:

*name*: a name for the suite. For simple packages, `test` or the package name are good candidates. In the Dart SDK, for example, it would be things like `language`, `corelib`, etc.

*kind*: always `Compilation` for this kind of suite.

*source*: a relative URI to a Dart program that implements the steps in the suite. This program must provide a top-level method with this name and
 signature:

```dart
Future<TestContext> createSuiteContext(Compilation suite) async { ... }
```

The Kernel package contains a complete [suite](https://github.com/dart-lang/kernel/blob/closure_conversion/test/closures/suite.dart) that should serve as a good example. For example, the suite stores an `AnalysisContext` in its `TestContext` and is this way able to reuse the same `AnalysisContext` in all tests.

*path*: a URI relative to the configuration file which is the root directory of all files in this suite. For now, only file URIs are supported. Each file is passed to the first step in the suite.

*status*: a URI relative to the configuration file which lists the status of tests.

*pattern*: a list of regular expressions that match file names that are tests.

*exclude*: a list of regular expressions that exclude files from being included in this suite.

#### Dart (combined)

The `Dart (combined)` suite is for running unit tests written in Dart. Each test is a Dart program with a main method that can be run directly from the command line.

The suite generates a new Dart program which combines all the tests included in the suite, so they can all be run (in sequence) in the same process. Such tests must be co-operative and must clean up after themselves.

You can use any test-framework, for example, `package:test` in these individual programs, as long as the frameworks are well-behaved with respect to static state.

Here is a complete example of a `Dart (combined)` suite:

```json
{
  "suites": [
    {
      "name": "my-package",
      "path": "test/",
      "kind": "Dart (combined)",
      "pattern": [
        "_test\\.dart$"
      ],
      "exclude": [
        "/test/golden/"
      ]
    }
  ]
}
```

The properties of a `Dart (combined)` suite are:

*name*: a name for the suite. For simple packages, `test` or the package name are good candidates. In the Dart SDK, for example, the names could be the name of the component that's tested by this suite's unit tests, for example, `dart2js`.

*path*: a URI relative to the configuration file which is the root directory of all files in this suite. For now, only file URIs are supported.

*kind*: always `Dart (combined)` for this kind of suite.

*pattern*: a list of regular expressions that match file names that are tests.

*exclude*: a list of regular expressions that exclude files from being included in this suite.

### Configuring Analyzed Programs

By default, all tests in `Dart (combined)` suites are analyzed by the `dartanalyzer`. It is possible to exclude tests from analysis, and it's possible to add additional files to be analyzed. Here is a complete example of a `Dart (combined)` suite and analyzer configuration:

```json
{
  "suites": [
    {
      "name": "my-package",
      "path": "test/",
      "kind": "Dart (combined)",
      "pattern": [
        "_test\\.dart$"
      ],
      "exclude": [
        "/test/golden/"
      ]
    }
  ],
  "analyze": {
    "uris": [
      "lib/",
    ],
    "exclude": [
      "/third_party/"
    ]
  }
}
```

The properties of the `analyze` section are:

*uris*: a list of URIs relative to the configuration file that should also be analyzed. For now, only file URIs are supported.

*exclude*: a list of regular expression that matches file names that should be excluded from analysis. For now, the files are still analyzed but diagnostics are suppressed and ignored.
