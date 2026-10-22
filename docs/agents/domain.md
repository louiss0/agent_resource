# Domain Docs

## Layout: single-context

- `GLOSSARY.md` at the repository root: domain vocabulary.
- `docs/adr/`: architectural decision records.

## Before exploring

Read the root glossary and ADRs relevant to the area being explored.

If these files or directories do not exist, proceed silently. Do not
flag their absence or suggest creating them upfront. The domain-modeling
skill creates them lazily when terms or decisions are resolved.

## Use the glossary's vocabulary

Use defined domain terms in issue titles, proposals, hypotheses, and test
names. Avoid synonyms the glossary explicitly excludes.

If a needed concept is missing, reconsider whether it belongs to the
project's vocabulary; note genuine gaps for domain-modeling.

## Flag ADR conflicts

Surface contradictions explicitly instead of silently overriding decisions:

> Contradicts ADR-0007 (...), but worth reopening because…
