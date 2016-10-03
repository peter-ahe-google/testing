// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library testing.test_description;

import 'dart:io' show
    File,
    FileSystemEntity;

class TestDescription implements Comparable<TestDescription> {
  final Uri root;
  final File file;

  TestDescription(this.root, this.file);

  Uri get uri => file.uri;

  String get shortName {
    String baseName = "$uri".substring("$root".length);
    return baseName.substring(0, baseName.length - ".dart".length);
  }

  static TestDescription from(
      Uri root, FileSystemEntity entity, {Pattern pattern}) {
    if (entity is! File) return null;
    pattern ??= "_test.dart";
    String path = entity.uri.path;
    bool hasMatch = false;
    if (pattern is String) {
      if (path.endsWith(pattern)) hasMatch = true;
    } else if (path.contains(pattern)) {
      hasMatch = true;
    }
    return hasMatch ? new TestDescription(root, entity) : null;
  }

  int compareTo(TestDescription other) => "$uri".compareTo("${other.uri}");
}
