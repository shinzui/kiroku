#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
baseline_file="$script_dir/results/baseline.csv"
temporary_root="${TMPDIR:-/tmp}"
temporary_dir="$(mktemp -d "$temporary_root/kiroku-baseline-coverage.XXXXXX")"

cleanup() {
    case "$temporary_dir" in
        "$temporary_root"/kiroku-baseline-coverage.*)
            rm -rf -- "$temporary_dir"
            ;;
        *)
            printf 'refusing to clean unexpected temporary path: %s\n' "$temporary_dir" >&2
            return 1
            ;;
    esac
}
trap cleanup EXIT

current_names="$temporary_dir/current-names.txt"
baseline_rows="$temporary_dir/baseline-rows.csv"
baseline_names="$temporary_dir/baseline-names.txt"

cd "$repo_root"

if [[ ! -s "$baseline_file" ]]; then
    printf 'baseline is empty or missing: %s\n' "$baseline_file" >&2
    exit 1
fi

IFS= read -r header < "$baseline_file"
if [[ "$header" != "Name,Mean (ps),2*Stdev (ps)" ]]; then
    printf 'unexpected baseline header in %s: %s\n' "$baseline_file" "$header" >&2
    exit 1
fi

benchmark_binary="$(cabal list-bin kiroku-store:kiroku-store-bench)"
if [[ ! -x "$benchmark_binary" ]]; then
    printf 'historical benchmark binary is not executable: %s\n' "$benchmark_binary" >&2
    printf 'build it first with: cabal build kiroku-store:kiroku-store-bench\n' >&2
    exit 1
fi

"$benchmark_binary" --list-tests | rg '^All\.' | LC_ALL=C sort > "$current_names"
sed '1d' "$baseline_file" > "$baseline_rows"

if ! awk -F, '
    NF != 3 {
        printf "baseline row %d has %d CSV fields; benchmark names must not contain commas: %s\n", NR + 1, NF, $0 > "/dev/stderr"
        invalid = 1
    }
    END { exit invalid }
' "$baseline_rows"; then
    exit 1
fi

cut -d, -f1 "$baseline_rows" | LC_ALL=C sort > "$baseline_names"

if rg -n ',' "$current_names" >/dev/null; then
    printf 'current benchmark names contain a comma; rename them or upgrade this helper to a real CSV parser:\n' >&2
    rg -n ',' "$current_names" >&2
    exit 1
fi

if ! diff -u --label baseline.csv --label current-benchmarks "$baseline_names" "$current_names"; then
    printf 'historical benchmark names do not exactly match baseline.csv\n' >&2
    exit 1
fi

benchmark_count="$(wc -l < "$current_names" | tr -d ' ')"
printf 'baseline coverage OK: %s historical benchmarks match exactly\n' "$benchmark_count"
