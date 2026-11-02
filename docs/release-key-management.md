# Release key management

## Short answer

No new SSH keys were generated, and no existing keys were rewritten or
rotated. The release setup reuses the existing Sheltons-CLI-Projects deploy
keypairs found in `~/.ssh`.

The private keys were copied into new, project-named 1Password items for the
Agent Resource release workflow. The public keys were used only to identify
the matching local keypairs. No public or private key was committed to this
repository.

## Existing keypairs used

| Purpose | Existing local keypair in `~/.ssh` | Target repository |
| --- | --- | --- |
| Homebrew | `Sheltons-CLI-Projects-homebrew-the-code-fixer-23-deploy-key` and `.pub` | `Sheltons-CLI-Projects/homebrew-the-code-fixer-23` |
| WinGet | `Sheltons-CLI-Projects-winget-pkgs-deploy-key` and `.pub` | `Sheltons-CLI-Projects/winget-pkgs` |

These were already project-named deploy keys. The setup did not convert a
general-purpose key into a project-specific key, and it did not change the
access that either key already has. Reusing a key for another project does not
isolate its access: every repository that accepts the corresponding public key
continues to trust the same private key.

The local files were not edited. Their private/public fingerprints were
checked to confirm that each pair matched.

## What happened to the public keys

The shared 1Password links contained public keys and repository metadata. Those
public keys were compared with local `.pub` files to locate the correct
keypairs.

No public keys were added, removed, replaced, or rotated on GitHub. The setup
did not change deploy-key settings on either target repository.

Public keys are not secret and are not stored as GitHub Actions secrets for
this workflow.

## What happened to the private keys

The private-key files were read locally and encoded as base64 without changing
their underlying bytes. A base64 copy of each private key was stored in a new
API Credential item in 1Password's `Development` vault:

| 1Password item | Credential contents |
| --- | --- |
| `agent-resource-homebrew-deploy-key` | Base64-encoded Homebrew private key |
| `agent-resource-winget-deploy-key` | Base64-encoded WinGet private key |

This creates additional protected copies of the existing private keys in
1Password. It does not create new keys or restrict the old keys to Agent
Resource.

The stored base64 values were read back and checked against the local private
key files. The configured 1Password service account was also verified to have
read access to both items. Private-key values were not printed or committed.

During setup, incomplete SSH Key and Secure Note items that did not contain
private-key material were archived. The API Credential items above are the
items used by the workflow.

## What is stored in GitHub

The repository has one service-account secret:

- `OP_SERVICE_ACCOUNT_TOKEN`

It also has two repository secrets containing 1Password secret references,
not private-key contents:

- `GORELEASER_HOMEBREW_DEPLOY_KEY_OP_REFERENCE`
- `GORELEASER_WINGET_DEPLOY_KEY_OP_REFERENCE`

Those references point to the `credential` fields of the two 1Password items.
The references identify where the deploy keys are stored; the private keys
remain in 1Password.

## What happens during a release

1. `1password/load-secrets-action` uses `OP_SERVICE_ACCOUNT_TOKEN` to resolve
   the two configured references.
2. The action exports the base64 credentials only within the publish job.
3. A Bash step decodes each value into a temporary file under `RUNNER_TEMP`.
4. The files receive mode `0600`, so only the job's user can read them.
5. GoReleaser receives those file paths through
   `GORELEASER_HOMEBREW_DEPLOY_KEY_PATH` and
   `GORELEASER_WINGET_DEPLOY_KEY_PATH`.
6. GoReleaser uses SSH with those keys to update the Homebrew tap and WinGet
   fork.

The decoded private keys are temporary runner files. They are not included in
release archives or repository contents.

## Security implication

This setup reuses existing credentials rather than creating per-repository or
per-application keypairs. If one of these private keys is compromised, every
repository where its public key is authorized may be affected. Rotating the key
later requires updating the 1Password credential and the corresponding public
deploy key on each repository that uses it.
