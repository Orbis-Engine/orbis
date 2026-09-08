# Versioning and branches

Two rules, and a check that enforces the first one so it does not depend on
anybody remembering.

## A feature is a branch

Every feature gets its own branch off `master`, never stacked onto whatever
branch happens to be checked out.

```sh
git checkout master
git pull
git checkout -b lighting-probes
```

Stacking is how two unrelated pieces of work end up unreviewable together, and
how reverting one means reverting both. If a second feature genuinely depends
on the first, say so in the pull request and merge them in order.

## A feature is a version

Every feature bumps the version of each package it changes, and adds a line to
that package's `CHANGELOG.md`.

Pre-alpha, so semantic versioning's promises are read one place to the left of
where they usually are:

| | |
| --- | --- |
| `0.1.0` → `0.2.0` | A feature, or a breaking change. Both, at this stage. |
| `0.1.0` → `0.1.1` | A fix that changes no signature and adds no behaviour. |

Once something reaches `1.0.0`, the ordinary rules apply and a breaking change
takes the major.

### Why bump per feature rather than per release

Because the version is the only thing a consumer can point at. Once these
repositories are public, somebody depending on `orbis_filament` at a git
revision has no way to say "the one before the render graph landed" — but they
can say `^0.4.0`. A version that only moves at release time is a version that
is wrong for most of the month.

It also makes a changelog possible to write. A changelog assembled at release
time from a month of commits is a list of commit subjects; one written a line
at a time, by the person who made the change, is a changelog.

### What counts as a feature

Anything a consumer could notice: a new API, a changed signature, a behaviour
that differs, a bug they might have worked around. Formatting, comments,
tests, CI and documentation do not.

## The check

`tool/check_versions.sh` compares the working branch against `master`. For
every package with a changed file under `lib/`, it requires:

- the package's `version:` to differ from the one on `master`, and
- its `CHANGELOG.md` to mention the new version.

It runs in CI on every pull request. A branch that only touches tests, docs,
comments or CI passes without a bump, because those are not features.

### When library code changed but nothing did

A reformat touches `lib/` and is not a feature, and the check cannot tell the
difference: `dart format` joining two lines into one changes how many lines
there are, and git's whitespace-blind comparison works within a line rather
than across two. Rather than guess, say so in a commit message:

```
Version-exempt: orbis_camera orbis_light - dart format only
Version-exempt: all - repository-wide reformat
```

It names the packages it covers, and exempts only those. That matters more
than it looks: an exemption that covered the whole branch would also excuse
every package changed in later commits, so one reformat early on would quietly
wave through the feature that landed after it — the exact failure this check
exists to prevent, reintroduced by the escape hatch meant to make it usable.

Making the exemption a line in the history rather than a silent skip is the
rest of the point. It sits in the log next to its reason, and a branch full of
them is visible.

Run it before opening the pull request:

```sh
./tool/check_versions.sh
```
