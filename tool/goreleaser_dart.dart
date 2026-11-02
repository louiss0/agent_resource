import 'dart:io';

/// Adapts GoReleaser's generic build command contract to Dart native builds.
///
/// With AGENT_RESOURCE_PREBUILT_DIR set, copies the native binary produced and
/// qualified by an earlier workflow job instead of compiling it again.
Future<void> main(List<String> args) async {
  final request = _parseArguments(args);
  final output = File(request.output);
  output.parent.createSync(recursive: true);

  final prebuiltRoot = Platform.environment['AGENT_RESOURCE_PREBUILT_DIR'];
  if (prebuiltRoot != null && prebuiltRoot.isNotEmpty) {
    await _copyPrebuilt(prebuiltRoot, request.output);
    return;
  }

  final version = Platform.environment['AGENT_RESOURCE_VERSION'];
  if (version == null || version.isEmpty) {
    throw StateError('AGENT_RESOURCE_VERSION must be set by GoReleaser.');
  }

  final result = await Process.run(Platform.resolvedExecutable, [
    'compile',
    'exe',
    '-DAGENT_RESOURCE_VERSION=$version',
    '-o',
    request.output,
    request.entryPoint,
  ]);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    exitCode = result.exitCode;
  }
}

({String output, String entryPoint}) _parseArguments(List<String> args) {
  String? output;
  final positional = <String>[];

  for (var index = 0; index < args.length; index++) {
    final argument = args[index];
    if (argument.startsWith('-ldflags=')) {
      continue;
    }
    if (argument == '-o') {
      if (output != null || index + 1 == args.length) {
        throw ArgumentError('GoReleaser must supply exactly one -o path.');
      }
      output = args[++index];
      continue;
    }
    positional.add(argument);
  }

  if (output == null || positional.length != 1) {
    throw ArgumentError(
      'Expected GoReleaser arguments: -ldflags= -o <output> <entry-point>.',
    );
  }
  return (output: output, entryPoint: positional.single);
}

Future<void> _copyPrebuilt(String root, String output) async {
  final environment = Platform.environment;
  final goos = environment['GOOS'];
  final goarch = environment['GOARCH'];
  if (goos == null || goos.isEmpty || goarch == null || goarch.isEmpty) {
    throw StateError(
      'GoReleaser must supply GOOS and GOARCH for prebuilt input.',
    );
  }

  final binary = goos == 'windows' ? 'agent_resource.exe' : 'agent_resource';
  final source = File(
    [root, 'native-$goos-$goarch', binary].join(Platform.pathSeparator),
  );
  if (!source.existsSync()) {
    throw StateError('Qualified native binary not found: ${source.path}');
  }
  source.copySync(output);

  if (goos != 'windows' && !Platform.isWindows) {
    final chmod = await Process.run('chmod', ['+x', output]);
    if (chmod.exitCode != 0) {
      stderr.write(chmod.stderr);
      throw StateError('Could not make $output executable.');
    }
  }
}
