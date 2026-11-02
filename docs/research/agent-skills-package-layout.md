# Agent Skills package-directory layout

- **Retrieved:** 2026-10-29 UTC.
- **Question:** Does the Agent Skills specification impose an exhaustive package-root allowlist consisting of `SKILL.md`, `scripts/`, `references/`, and `assets/`? What is `assets/` for?
- **Method:** Read the official rendered specification and the source document in the official `agentskills/agentskills` repository. No secondary source is used as authority.

## Conclusion

**The claim is false.** The specification requires `SKILL.md`, recommends conventional directories for common content types, and expressly permits additional files and directories. It does not impose the same exhaustive allowlist as Agent Resource's restricted installation policy.

`assets/` is now accepted by Agent Resource's product policy as requested. Other product restrictions remain distinct from specification validity and should not be presented as upstream requirements.

## Primary sources

- [Official Agent Skills specification — Directory structure](https://agentskills.io/specification#directory-structure)
- [Official Agent Skills specification — Optional directories](https://agentskills.io/specification#optional-directories)
- [Official source document: `agentskills/agentskills`, `docs/specification.mdx`](https://github.com/agentskills/agentskills/blob/main/docs/specification.mdx)
- [Raw official source used for the quotations below](https://raw.githubusercontent.com/agentskills/agentskills/main/docs/specification.mdx)

## Evidence

### Required minimum, not a closed list

The directory-structure section states:

> “A skill is a directory containing, at minimum, a `SKILL.md` file:”

Its accompanying layout lists `SKILL.md`, `scripts/`, `references/`, and `assets/`, followed by:

> `... # Any additional files or directories`

“At minimum” and the explicit additional-entry line contradict an exhaustive four-entry allowlist.

### Additional files are expressly permitted

The optional-directories section states:

> “A skill directory may contain any files and directories beyond the required `SKILL.md`. The conventions below are recommendations for organizing common types of content.”

Thus, the named directories are organizational recommendations, not the only permitted root entries. Extra root files and directories are not intrinsically invalid under this part of the specification.

### Purpose of `assets/`

The same section states:

> “`assets/` contains static resources:”

It lists:

- templates, including document and configuration templates;
- images, including diagrams and examples;
- data files, including lookup tables and schemas.

The specification does not prescribe an asset filename, extension, subdirectory, or manifest allowlist in this section. Agent Resource still applies its own recursive type, link, size, and entry safety checks when installing assets.

## Requirement versus product policy

| Proposition | Assessment |
| --- | --- |
| `SKILL.md` is required. | Specification requirement. |
| `scripts/`, `references/`, and `assets/` are useful organizational conventions. | Specification recommendation. |
| Only `SKILL.md`, `scripts/`, `references/`, and `assets/` may exist. | Not supported; contradicted by the specification's explicit permission for additional files and directories. |
| Additional root files and directories can exist. | Expressly permitted by the specification. |
| Agent Resource rejects entries outside its chosen allowlist. | Agent Resource product policy, not upstream specification compliance. |

Diagnostics should therefore say **“unsupported by Agent Resource’s restricted layout policy”** rather than implying that every rejected additional entry is an invalid Agent Skill. Whether to retain each product restriction is a separate product decision.

## Implementation relationship

Direct install and pack install/update now stage an inert copy before admission and update comparison. In that copy, root non-`SKILL.md` Markdown moves to `references/`, and common root images (`png`, `jpg`, `jpeg`, `gif`, `webp`, `bmp`, `ico`, `svg`, `avif`, `tif`, `tiff`, case-sensitive) move to `assets/`; exact literal references in `SKILL.md` are rewritten. Other root files, including code and unknown extensions, remain rejected. Sources and image bytes are never modified, collisions fail safely, and warnings advise contributing or requesting standard support-directory layout upstream. `source-link` rejects migration-required sources to protect the user-owned target. Argument-hint handling remains a prompt concern, not part of migration. Nested `assets/` content is preserved and covered by bounded manifest validation; legacy lifecycle recovery remains separate from new-installation eligibility.
