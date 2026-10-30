# GitHub source update evidence

## Scope and evidence limits

This report describes Git/GitHub evidence for resolving and comparing source installations. It does **not** choose an update policy, version-selection policy, or trust policy.

Sources are first-party Git and GitHub documentation retrieved through live web search. No authenticated API experiment was performed. The search interface provided official-document excerpts and summaries; raw OpenAPI schema retrieval was not available. In particular, this research does **not** establish that an asset digest is non-null for every historical asset or GitHub deployment.

## 1. Branches: retain resolved commits, not just names

GitHub’s Git References API resolves a qualified reference to an object type and SHA. Its update endpoint accepts a target SHA and a `force` option; force permits updates that are not fast-forwards. Consequently, a branch name is a mutable selector, not an immutable snapshot identifier. [1]

Git documents normal branch advancement as a fast-forward relationship and explains that forcing a push can replace history. A changed branch tip therefore does not, by itself, establish that the new tip descends from the installed one. [2]

GitHub’s compare-commits API provides comparison evidence, including status, ahead/behind counts, and merge-base information. Comparing the previously recorded SHA with the newly resolved SHA can distinguish ancestry relationships rather than relying on dates. [3]

**Inference:** useful evidence consists of the requested branch ref, previous resolved commit, newly resolved commit, and comparison result. A missing old commit or failed comparison establishes an inability to prove the relationship—not automatically a deletion, rollback, or successful update. Equality of endpoint observations also cannot reveal intermediate movement away from and back to the same SHA.

## 2. Exact commits and tags are different kinds of identity

Git commit objects contain a tree, parent links, author and committer identities and timestamps, and a message. Parent links define history; timestamps are recorded object fields, not a separate authoritative ordering service. [4]

An exact commit identifier identifies a Git object rather than “the newest version.” A different commit can preserve the same relevant files while changing other files, metadata, or history. **Inference:** commit-change detection and installed-resource-content-change detection answer different questions. A commit tree and the digests of selected resource content can explain that distinction.

Git distinguishes lightweight tags from annotated tags. An annotated tag is its own object and points to another object; the GitHub Tags API creates annotated tag objects separately from refs. [5][6] The References API can update or delete tag refs subject to applicable repository restrictions. [1]

**Inference:** for a tag, retain both the requested tag ref and its resolved object identity; when it is annotated, distinguish the tag-object SHA from the ultimate commit SHA. A changed tag object need not imply changed commit content, and a familiar tag name is not proof of unchanged content.

## 3. Releases: database identity, tag identity, and commit identity

GitHub Release responses expose release `id`, `tag_name`, `target_commitish`, release text and name, draft/prerelease flags, timestamps, archive URLs, attached assets, and an `immutable` field. The REST API supports editing and deleting releases. [7]

`target_commitish` is an input used to identify where a new tag should be created; it is not a substitute for independently resolving an existing release tag to its commit. GitHub’s release documentation describes releases as being based on Git tags. [7][8]

**Inference:** release ID identifies the API release entity; tag name identifies a mutable ref unless immutability applies; resolved commit identifies repository source. These should not be collapsed into a single “release version” field.

For ordinary mutable releases, changes to release notes or flags need not change repository files. Conversely, a moved tag or replaced attached asset can change installation input without a new human-readable release name.

### Immutable releases are a qualified exception

GitHub now documents immutable releases: publication locks associated tags and attached assets and creates an attestation recording the release tag, commit SHA, and assets. [9]

Accordingly, “all releases and tags can always be changed” is too broad. Immutability must be evaluated for the specific release and deployment. It does not follow merely from the presence of a release name or tag.

Attestation and publisher-authentication policy are outside this ticket’s scope; the existence of this first-party mechanism is relevant to provenance evidence.

## 4. Attached release assets

The Release Assets API exposes asset ID, name, label, state, size, content type, timestamps, download URL, and a digest such as `sha256:…`. It supports metadata updates, deletion, and upload. Ordinary assets can be deleted and a replacement uploaded under the same filename; immutable releases restrict such mutation. [10][9]

**Inference:**

- Filename and browser-download URL are locators, not immutable byte identities.
- Asset ID distinguishes API entities but is not itself a content checksum.
- A digest provides byte-comparison evidence when present; calculating a digest of the actual downloaded bytes also records what was consumed.
- `updated_at` alone does not identify which bytes were downloaded, particularly because asset metadata can be edited.
- Missing digest, unavailable download, and changed digest are distinct observations.

This research did not confirm universal digest availability or inspect the raw schema’s nullability contract. A raw supported-version OpenAPI schema or authenticated sample of the relevant assets would settle those narrower questions.

## 5. Release archives are not attached assets

GitHub automatically supplies ZIP/tar source archives for repository refs, including those shown with releases. These are repository snapshots, not necessarily publisher-uploaded build artifacts. [8][11]

GitHub documents that branch and tag archives can change when their refs move. Commit-addressed archives provide stable extracted file contents subject to documented conditions. Archive compression may change over time; repository names appear in archive directory structure, so renaming a repository affects that structure. [11]

**Inference:** compressed archive-byte identity is not interchangeable with extracted repository-content identity. Record whether installation consumed an automatically generated source archive or a particular attached asset. A release’s source commit does not, without additional evidence, establish that an attached binary or package was built from that commit.

## 6. Timestamps are observations, not version identities

GitHub documents `created_at` on the latest-release endpoint as the date of the commit used for the release, rather than when the release was drafted or published. Release responses also expose `published_at`; assets have their own `created_at` and `updated_at`. [7][10]

Git commit author and committer dates are separate fields, and commit construction supports explicitly supplied dates. [4][12]

**Inference:** these timestamps describe different events and cannot safely be treated as one universal “source version timestamp.” Neither a larger timestamp nor an unchanged timestamp proves a newer version, ancestry, or identical installed content. A locally recorded observation time is yet another event and should be labeled accordingly.

## 7. “Latest,” prereleases, and version ordering

GitHub provides draft and prerelease flags and a latest-release endpoint. Drafts and prereleases cannot be marked latest. The release API also exposes `make_latest` settings of `"true"`, `"false"`, and `"legacy"`; legacy selection uses creation date and higher semantic version. [7]

The documentation also describes the latest-release endpoint using creation-date language. **Limitation:** this research did not experimentally reconcile all interactions between explicit latest designation, legacy selection, and endpoint behavior. Do not derive a complete client-side replica of GitHub’s latest-selection algorithm from one sentence of documentation.

Release names and tag names are not universally guaranteed to be semantic versions. Git’s tag documentation supports `version:refname` sorting, whose results can be influenced by `versionsort.suffix`; ordinary tag sorting can be lexicographic. [5]

**Inference:** GitHub’s latest designation, semantic-version precedence, lexical ordering, publication chronology, and Git ancestry are distinct signals. A prerelease boolean is release metadata, not proof that a tag string follows SemVer. Which signals should govern candidate selection remains a product decision.

## Evidence summary

| Source | Resolution evidence | Useful later comparison | Not sufficient alone |
|---|---|---|---|
| Branch | Qualified ref and resolved commit SHA | SHA equality; ancestry comparison | Branch name, timestamp |
| Exact commit | Commit SHA; selected tree/content evidence | Commit and selected-content equality | Date as “newness” |
| Tag | Qualified ref; tag-object SHA if annotated; resolved commit | Ref/object/commit changes separately | Tag text |
| Release | Release ID, flags, tag resolution, timestamps, immutability | Entity metadata and source changes separately | Release name, `target_commitish` |
| Attached asset | Release/asset IDs, locator, digest and consumed bytes | Identity and byte-digest changes | Filename, URL, timestamp |
| Source archive | Archive kind and resolved commit; extracted-content evidence | Source/content comparison | Compressed-byte equality expectation |

These are evidence capabilities and limitations, **not a mandated persistence schema or update policy**.

## Sources

1. GitHub, **REST API endpoints for Git references**: https://docs.github.com/en/rest/git/refs  
2. Git, **git-push**: https://git-scm.com/docs/git-push  
3. GitHub, **REST API endpoints for commits — Compare two commits**: https://docs.github.com/en/rest/commits/commits#compare-two-commits  
4. Git, **Git data model**: https://git-scm.com/docs/gitdatamodel.html  
5. Git, **git-tag**: https://git-scm.com/docs/git-tag  
6. GitHub, **REST API endpoints for Git tags**: https://docs.github.com/en/rest/git/tags  
7. GitHub, **REST API endpoints for releases**: https://docs.github.com/en/rest/releases/releases  
8. GitHub, **About releases**: https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases  
9. GitHub, **Immutable releases**: https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases  
10. GitHub, **REST API endpoints for release assets**: https://docs.github.com/en/rest/releases/assets  
11. GitHub, **Downloading source code archives**: https://docs.github.com/en/repositories/working-with-files/using-files/downloading-source-code-archives  
12. Git, **git-commit-tree**: https://git-scm.com/docs/git-commit-tree
