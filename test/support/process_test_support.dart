import 'dart:async';
import 'dart:convert';
import 'dart:io';

final class CliProcessResult {
  const CliProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

final class CliProcessTimeout implements Exception {
  const CliProcessTimeout({
    required this.executable,
    required this.arguments,
    required this.stdout,
    required this.stderr,
  });

  final String executable;
  final List<String> arguments;
  final String stdout;
  final String stderr;

  @override
  String toString() =>
      'Process timed out: $executable ${arguments.join(' ')}\n'
      'stdout: $stdout\n'
      'stderr: $stderr';
}

Future<CliProcessResult> runDartScript({
  required String script,
  required String packageConfig,
  required List<String> arguments,
  required Directory workingDirectory,
  required Map<String, String> environment,
  Duration timeout = const Duration(seconds: 20),
}) => runProcess(
  Platform.resolvedExecutable,
  ['--packages=$packageConfig', script, ...arguments],
  workingDirectory: workingDirectory,
  environment: environment,
  timeout: timeout,
);

Future<CliProcessResult> runProcess(
  String executable,
  List<String> arguments, {
  required Directory workingDirectory,
  required Map<String, String> environment,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final Process process;
  try {
    process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory.path,
      environment: environment,
      includeParentEnvironment: false,
    ).timeout(timeout);
  } on TimeoutException {
    throw CliProcessTimeout(
      executable: executable,
      arguments: arguments,
      stdout: '',
      stderr: '',
    );
  }

  final stdout = _OutputCollector(process.stdout);
  final stderr = _OutputCollector(process.stderr);
  unawaited(_closeInput(process));
  final completion = Future.wait<dynamic>([
    process.exitCode,
    stdout.done,
    stderr.done,
  ]);

  try {
    final values = await completion.timeout(timeout);
    return CliProcessResult(
      exitCode: values[0] as int,
      stdout: stdout.text,
      stderr: stderr.text,
    );
  } on TimeoutException {
    final terminated = await _killAndReap(process);
    await Future.wait([stdout.drain(), stderr.drain()]);
    await Future.wait([stdout.cancel(), stderr.cancel()]);
    if (!terminated) {
      throw StateError(
        'Timed out and could not terminate $executable ${arguments.join(' ')} '
        '(PID ${process.pid}).\nstdout: ${stdout.text}\nstderr: ${stderr.text}',
      );
    }
    throw CliProcessTimeout(
      executable: executable,
      arguments: arguments,
      stdout: stdout.text,
      stderr: stderr.text,
    );
  }
}

const _streamCancellationTimeout = Duration(seconds: 1);
const _processReapTimeout = Duration(seconds: 1);

Future<bool> _killAndReap(Process process) async {
  process.kill();
  if (await _reap(process)) return true;
  process.kill(ProcessSignal.sigkill);
  return _reap(process);
}

Future<bool> _reap(Process process) async {
  try {
    await process.exitCode.timeout(_processReapTimeout);
    return true;
  } on TimeoutException {
    return false;
  }
}

Future<void> _closeInput(Process process) async {
  try {
    await process.stdin.close().timeout(_streamCancellationTimeout);
  } on Object {
    // A process that exits while its input pipe is closing is already done.
  }
}

final class _OutputCollector {
  _OutputCollector(Stream<List<int>> source) {
    _subscription = const Utf8Decoder(allowMalformed: true)
        .bind(source)
        .listen(
          _buffer.write,
          onError: (Object _, StackTrace _) {},
          onDone: () {
            if (!_done.isCompleted) _done.complete();
          },
        );
  }

  final _buffer = StringBuffer();
  final _done = Completer<void>();
  late final StreamSubscription<String> _subscription;

  Future<void> get done => _done.future;
  String get text => _buffer.toString();

  Future<void> drain() async {
    try {
      await done.timeout(_streamCancellationTimeout);
    } on TimeoutException {
      // Descendants may keep pipe handles open after the direct child exits.
    }
  }

  Future<void> cancel() async {
    try {
      await _subscription.cancel().timeout(_streamCancellationTimeout);
    } on TimeoutException {
      // A broken pipe must not make cleanup wait forever.
    }
  }
}

Map<String, String> isolatedEnvironment(Directory sandbox) {
  final home = Directory('${sandbox.path}${Platform.pathSeparator}home')
    ..createSync(recursive: true);
  final config = Directory('${sandbox.path}${Platform.pathSeparator}config')
    ..createSync(recursive: true);
  final temp = Directory('${sandbox.path}${Platform.pathSeparator}temp')
    ..createSync(recursive: true);
  final path = Platform.environment['PATH'];
  final systemRoot =
      Platform.environment['SystemRoot'] ?? Platform.environment['WINDIR'];
  final comSpec = Platform.environment['ComSpec'];

  final environment = <String, String>{
    'PATH': ?path,
    'SystemRoot': ?systemRoot,
    'ComSpec': ?comSpec,
    'TEMP': temp.path,
    'TMP': temp.path,
    'HOME': home.path,
    'USERPROFILE': home.path,
    'APPDATA': config.path,
    'LOCALAPPDATA': config.path,
    'XDG_CONFIG_HOME': config.path,
    'XDG_CACHE_HOME': config.path,
    'XDG_DATA_HOME': config.path,
    'XDG_STATE_HOME': config.path,
    'PUB_CACHE': '${home.path}${Platform.pathSeparator}pub-cache',
    'NO_COLOR': '1',
  };

  return environment;
}
