import 'dart:convert';

import 'package:mamba/executor.dart';
import 'package:test/test.dart';

/// Context plan identities are always `pln_<64hex>`.
final RegExp contextPlanIdPattern = RegExp(r'^pln_[a-f0-9]{64}$');

/// Location controls shared by the read, authoring and delete suites.
List<String> contextCliArgs({bool includeInjectRoots = false}) => <String>[
  '--cwd',
  '/sandbox/project/',
  if (includeInjectRoots) ...<String>['--project-root', '/sandbox/project/'],
  '--home',
  '/sandbox/home/',
  if (includeInjectRoots) ...<String>[
    '--claude-config-dir',
    '/sandbox/home/claude/',
    '--codex-home',
    '/sandbox/home/codex/',
    '--pi-agent-dir',
    '/sandbox/home/pi/',
  ],
  '--state-dir',
  '/sandbox/state/',
];

/// Builds an invocation for one context child command.
List<String> contextCommandArgs(
  String verb,
  List<String> extra, {
  bool includeInjectRoots = false,
}) => <String>[
  'context',
  verb,
  ...extra,
  ...contextCliArgs(includeInjectRoots: includeInjectRoots),
];

/// Asserts the complete Mamba success result and decoded JSON envelope.
Map<String, dynamic> expectContextJsonSuccess(
  MambaExecutionResult result, {
  required String command,
  required String outcome,
  required Map<String, Object?> data,
  List<Object?> diagnostics = const <Object?>[],
}) {
  expect(
    result,
    isA<MambaSuccessResult>()
        .having((value) => value.exitCode, 'exit code', 0)
        .having((value) => value.output, 'output', isA<String>()),
  );
  final output = (result as MambaSuccessResult).output!;
  final decoded = jsonDecode(output);
  expect(
    decoded,
    equals(<String, Object?>{
      'schemaVersion': 1,
      'command': command,
      'outcome': outcome,
      'data': data,
      'diagnostics': diagnostics,
    }),
  );
  return decoded as Map<String, dynamic>;
}

/// Asserts the complete Mamba failure result for one context command.
void expectContextFailure(
  MambaExecutionResult result, {
  required String verb,
  required String code,
  int exitCode = 4,
  MambaExecutionPhase phase = MambaExecutionPhase.run,
}) {
  expect(
    result,
    isA<MambaFailureResult>()
        .having((value) => value.exitCode, 'exit code', exitCode)
        .having((value) => value.message, 'message', contains(code))
        .having((value) => value.output, 'output', isNull)
        .having((value) => value.error.phase, 'phase', phase)
        .having((value) => value.error.commandPath, 'command path', <String>[
          'agent_resource',
          'context',
          verb,
        ]),
  );
}

/// The complete metadata map used by context template read commands.
Map<String, Object?> contextTemplateData(
  String name, {
  required Object? byteLength,
  required Object? isEmpty,
  required Object? sha256,
  String? content,
}) => <String, Object?>{
  'name': name,
  'path': '/sandbox/state/context-templates/$name.md',
  'byteLength': byteLength,
  'isEmpty': isEmpty,
  'sha256': sha256,
  'content': ?content,
};
