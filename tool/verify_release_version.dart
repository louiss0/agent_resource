import 'dart:io';

import 'package:yaml/yaml.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError('Usage: verify_release_version.dart <version>');
  }

  final document = loadYaml(File('pubspec.yaml').readAsStringSync());
  if (document is! Map || document['version'] != args.single) {
    throw StateError(
      'The tag version ${args.single} must match the pubspec.yaml version.',
    );
  }
}
