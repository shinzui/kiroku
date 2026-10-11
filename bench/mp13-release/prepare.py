#!/usr/bin/env python3
"""Prepare reviewable release metadata without applying it to the working tree."""
import argparse
import difflib
import json
from pathlib import Path
import re
import subprocess
import tempfile

VERSIONS = {
    'kiroku-store': ('0.10.0.0', '0.11.0.0'),
    'kiroku-store-migrations': ('0.7.0.0', '0.7.1.0'),
    'kiroku-otel': ('0.2.0.11', '0.2.0.12'),
    'kiroku-cli': ('0.2.0.9', '0.2.0.10'),
    'kiroku-metrics': ('0.2.0.0', '0.3.0.0'),
    'shibuya-kiroku-adapter': ('0.6.0.0', '0.6.0.1'),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--date', required=True, help='Proposed release date; regenerate on actual release day')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    evidence = root / 'bench/mp13-release/evidence'
    published = json.loads((evidence / 'released.json').read_text())
    changes = {}
    for package, (old, new) in VERSIONS.items():
        if published[package]['current'] != old:
            raise SystemExit(f'{package}: registry evidence requires a new version review')
        path = f'{package}/{package}.cabal'
        original = (root / path).read_text()
        if not re.search(r'^version:\s+' + re.escape(old) + r'$', original, re.M):
            raise SystemExit(f'{package}: working version changed')
        text = re.sub(r'^(version:\s+)' + re.escape(old) + r'$', lambda m: m[1] + new, original, flags=re.M)
        text = text.replace('^>=0.10.0.0', '^>=0.11.0.0')
        if package == 'kiroku-metrics':
            text = text.replace('^>=0.2.0.9', '^>=0.2.0.10')
        changes[path] = text
        path = f'{package}/CHANGELOG.md'
        text = (root / path).read_text()
        if '## Unreleased' in text:
            text = text.replace('## Unreleased', f'## {new} — {args.date}', 1)
        else:
            heading, rest = text.split('\n', 1)
            text = heading + f'\n\n## {new} — {args.date}\n\n### Other Changes\n\n- Require `kiroku-store ^>=0.11.0.0` for the inspection cohort; the public API is unchanged.\n' + rest
        if package == 'kiroku-metrics':
            text = text.replace('- `ServerProviders` gains `webSocketChannels`; complete constructors must supply the declaration. Custom callers can update `defaultServerProviders`. New standalone record labels in the umbrella import may require qualified record updates.\n\n', '- New umbrella exports can make record labels ambiguous; qualify configuration record updates.\n\n')
            text = text.replace('* `ServerProviders` adds optional `storeBrowsing`; use `defaultServerProviders` plus record updates for custom composition.\n\n', '')
            text = text.replace('### Other Changes\n\n', '### Other Changes\n\n- Require `kiroku-store ^>=0.11.0.0` and `kiroku-cli ^>=0.2.0.10`. Construct the new `ServerProviders` from `defaultServerProviders`; full construction supplies all six fields.\n\n', 1)
        if package == 'kiroku-store-migrations':
            text = text.replace('final write-cost acceptance is tracked\n  by MasterPlan 13 before release.', 'write-cost evidence and its limitations are recorded\n  by MasterPlan 13. Publication remains gated by cumulative acceptance.')
        changes[path] = text
    blueprint = 'blueprints/kiroku-upgrade/blueprint.dhall'
    text = (root / blueprint).read_text().replace('version = Some "0.2.0"', 'version = Some "0.3.0"')
    text = text.replace('      ]\n    , tags', '      , S.BlueprintMigration::{\n        , from = "0.10.0.0"\n        , to = "0.11.0.0"\n        , prompt = ./migrations/0-10-to-0-11.md as Text\n        }\n      ]\n    , tags')
    changes[blueprint] = text
    changes['blueprints/kiroku-upgrade/migrations/0-10-to-0-11.md'] = (root / 'bench/mp13-release/upgrade.md').read_text()
    readme = 'blueprints/kiroku-upgrade/README.md'
    text = (root / readme).read_text().replace('## Version space', '| `0.10.0.0` | `0.11.0.0` | Inspection APIs, exhaustive effect/publisher matches, metrics configuration and protocol constructors, standalone hosting, and migration 0015 from migrations 0.7.1.0 |\n\n## Version space')
    changes[readme] = text
    patch = []
    stage = Path(tempfile.mkdtemp(prefix='mp13-release-proposal-'))
    for path, text in changes.items():
        original = (root / path).read_text() if (root / path).exists() else ''
        patch.extend(difflib.unified_diff(original.splitlines(True), text.splitlines(True), fromfile='a/' + path if original else '/dev/null', tofile='b/' + path))
        target = stage / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
    (evidence / 'release.patch').write_text(''.join(patch))
    (evidence / 'proposal.json').write_text(json.dumps({'date': args.date, 'versions': VERSIONS, 'source': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(), 'metadata_stage': str(stage), 'status': 'unapproved; not applied; not published'}, indent=2) + '\n')
    print(stage)


if __name__ == '__main__':
    main()
