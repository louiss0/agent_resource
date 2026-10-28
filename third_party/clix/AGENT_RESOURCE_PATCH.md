# Agent Resource Clix patch

Upstream: Clix 1.2.0 from `https://pub.dev/packages/clix/versions/1.2.0` (MIT).
Local package version: `1.2.0+agent-resource.1`.

The unmodified upstream package was copied into this worktree; the global pub
cache was not edited. `LICENSE` and upstream notices are retained.

Narrow changes:

- `ConsoleIO.readLine` throws `CliInputClosedException` on EOF instead of
  converting EOF into a blank answer that could accept a confirmation default.
- `MultiSelect` supports an explicit Select All action, retains native raw-key
  checkbox selection and preselection, maps cancellation separately from an
  empty selection, treats Ctrl-C/Escape as cancellation and EOF as failure,
  accepts an injectable byte stream for component tests, restores the exact
  prior echo/line modes, and restores cursor visibility on every handled exit.
- Escape-sequence reading distinguishes arrows from a standalone Escape with a
  bounded 50 ms continuation wait.

Dependency resolution pins this local package through `dependency_overrides`
while declaring the exact local package version in `dependencies`. Mamba 1.0.0
continues to re-export this same resolved Clix package. Application component
tests cover behavior; native terminal qualification remains OS-specific and is
not claimed from scripted tests alone.
