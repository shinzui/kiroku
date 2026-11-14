# shibuya-kiroku-adapter-upgrade

> Agent-guided upgrade guidance for projects consuming `shibuya-kiroku-adapter`,
> published as one edge per released adapter version window that needs
> judgement work.

**Version:** `0.1.0`

**Kind:** Blueprint migration. Run it with `seihou agent migrate`, not
`seihou agent run`: this blueprint declares no baseline and applies no modules.

## Why a separate blueprint

`kiroku-upgrade` keys its edges on the `kiroku-store` version. The adapter's
breaks usually come from Shibuya, and they can ship while the store moves only by
a patch, or not at all. For example, adapter 0.8.0.0 shipped with store 0.13.0.2,
whose library is unchanged. Adapter 0.8.0.0 also works with store 0.13.0.1, so no
store edge could be guaranteed to reach a project upgrading the adapter.

This blueprint keys its edges on the adapter itself. When an adapter edge also
needs a store edge, it declares that with `entails` on `kiroku-upgrade`, and the
project crosses that edge exactly once.

## Running it

A downstream framework, such as Keiro or Kioku, can declare that one of its edges
entails an edge here. A project that uses the adapter directly runs it by name:

```sh
seihou install https://github.com/shinzui/kiroku.git --module shibuya-kiroku-adapter-upgrade

seihou agent --debug migrate shibuya-kiroku-adapter-upgrade --from 0.7.0.1   # preview
seihou agent migrate shibuya-kiroku-adapter-upgrade --from 0.7.0.1           # run
```

## Declared edges

| From | To | Covers |
|---|---|---|
| `0.7.0.1` | `0.8.0.0` | `shibuya-core` 0.13: the strict `telemetry` field on both adapter configuration records and on Shibuya's `Adapter`; the `LinkOnly` default and how to opt out; the `process <processor>` span rename; batch-span roots; sibling Shibuya adapters that must move with it |

Edge `from` versions name the **last release before the break**. Seihou selects
an edge when its `from` is at or after the cursor, so `0.7.0.1` is reached by
every project on any 0.7 release.

## Version probe

```
jq -r '."install-plan"[] | select(."pkg-name"=="shibuya-kiroku-adapter") | ."pkg-version"' \
  dist-newstyle/cache/plan.json 2>/dev/null | sort -u | tail -1 | grep .
```

The probe is read-only. It reports what the build plan actually resolved, not a
declared bound. A project without a configured Cabal build, or without `jq`, gets
a warning and is asked for `--to`.

## For maintainers

Write the edge in the release commit, before tagging, so that consumers upgrading
on release day have it. Adapter 0.8.0.0 was published on 2026-11-14 without this
edge, and it was added the same day. Declare an edge only when a release needs
judgement work; a gap in the edges means no agent intervention was needed.

An edge must report itself *not applicable* and succeed when the project has
nothing to change. An edge whose required dependency is unreleased must stop
without reporting completion, so it can run again once the dependency exists.

```sh
seihou validate-blueprint blueprints/shibuya-kiroku-adapter-upgrade
```
