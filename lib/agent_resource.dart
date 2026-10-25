import 'package:mamba/mamba.dart';

import 'discover.dart';

/// Creates a fresh executor for the Agent Resource command-line application.
///
/// Keeping composition here lets the production executable and application
/// tests exercise the same metadata and command registration.
Executor createExecutor() => Executor(
  'agent_resource',
  'Manage resources consumed by AI coding harnesses.',
  '0.0.0',
  [DiscoverCommand(discoverProjectSkills)],
);
