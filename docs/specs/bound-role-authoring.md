# Explicit Codex bound-role authoring

This slice prepares the explicit Codex bound-role authoring path that the
atomic Agent-create migration will register. Nothing is registered here: the
public `agent create` route still owns its JSON request branch, and the
standalone and bound-role routes are switched together by the create ticket.

## What the slice adds

| Module | Role |
| --- | --- |
| `lib/src/authoring/bound_role_authoring_inputs.dart` | The typed native selections of one bound-role operation and their refusals. |
| `lib/src/services/bound_role_authoring_service.dart` | The handler that plans and publishes a reviewed bound-role operation. |

The handler reuses the existing `BoundRoleService`, parent-unit validators,
plan identity, stopped-client acknowledgement and transaction safeguards. It
adds no new parent authority, no implicit adoption and no implicit management.

## The native selections

| Selection | Meaning |
| --- | --- |
| `--role-key` | The Codex role key registered as `agents.<roleKey>`. One name segment. |
| `--config-file` | The declaring Codex config that owns the registration. |
| `--ownership` | `definition` publishes the definition only; `both` publishes the definition and registers the role. |
| `--definition-source` | The reviewed native Codex definition that is published. It may be the candidate the shared guided authoring flow reviewed. |
| `--definition-output` | The explicit placement of the published definition. |
| `--ack-clients-stopped` | The independent acknowledgement that native clients are stopped for a parent write. |

No operation-document option is part of this vocabulary. The retired JSON
request route is not reinterpreted; `boundRoleRequestMigrationGuidance` names
the replacement selections for the create ticket.

## Refusals before effects

- A missing, blank or nested role key is refused.
- A missing declaring config is refused.
- An unsupported ownership, a registration-only ownership for a create and a
  missing definition source are refused.
- A registration without the stopped-client acknowledgement is refused.
- A plan identity that does not match the current evidence is refused.
- An operation document used as a definition source is refused.
- An existing role registration is not adopted implicitly.

## Integration with the shared guided flow

The shared guided flow reviews a native definition and publishes it to a
reviewed candidate path. The bound-role handler installs that candidate and
registers the role in the declaring config. The reviewed plan identity covers
the candidate path, so the candidate must be stable between planning and
publication; a changed candidate is refused.

## Evidence

The focused behavior suites are `test/src/authoring/bound_role_authoring_inputs_test.dart`
and `test/src/services/bound_role_authoring_service_test.dart`. They exercise
the public service and native state seams on an injected memory filesystem.
No editor, Codex harness or other native client was launched, so no runtime
activation or save proof is claimed.
