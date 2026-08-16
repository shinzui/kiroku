# Kiroku development commands

# List all recipes
default:
    @just --list

# --- Services ---

# Start PostgreSQL via process-compose
[group('services')]
up:
    process-compose up -D

# Stop all services
[group('services')]
down:
    process-compose down

# --- Database ---

# Create the kiroku database if it doesn't exist
[group('database')]
create-database:
    @psql -lqt | cut -d \| -f 1 | grep -qw kiroku || createdb kiroku
    @echo "Database 'kiroku' ready"

# Initialize the schema with the embedded migration package
[group('database')]
init-schema:
    DATABASE_URL='dbname=kiroku' cabal run kiroku-store-migrate -- up

# Drop and recreate the database
[group('database')]
reset-database:
    dropdb --if-exists kiroku
    createdb kiroku
    just init-schema

# Open a psql session
[group('database')]
psql:
    psql -d kiroku

# Truncate postgres logs
[group('database')]
truncate-logs:
    truncate -s 0 $PGLOG

# --- Build ---

# Build the project
[group('build')]
build:
    cabal build all

# Run tests
[group('build')]
test:
    cabal test all

# Run every suite against one supported PostgreSQL major (17 or 18)
[group('build')]
test-pg MAJOR:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{MAJOR}}" in
      17|18) ;;
      *) echo "unsupported PostgreSQL major: {{MAJOR}} (supported: 17, 18)" >&2; exit 1 ;;
    esac
    # The suites reach PostgreSQL through ephemeral-pg, which runs whichever
    # server it finds on PATH. Assert the shell really put the requested major
    # there, so a matrix run cannot silently test one major twice.
    nix develop ".#postgresql{{MAJOR}}" --command bash -euo pipefail -c '
      found=$(postgres --version | grep -oE "[0-9]+" | head -1)
      if [ "$found" != "{{MAJOR}}" ]; then
        echo "expected PostgreSQL {{MAJOR}} on PATH, found $found" >&2
        exit 1
      fi
      echo "== $(postgres --version) =="
      cabal test all
    '

# Run every suite against both supported PostgreSQL majors
[group('build')]
test-matrix:
    just test-pg 17
    just test-pg 18

# --- Benchmarks ---

# Run benchmarks
[group('benchmarks')]
bench:
    cabal bench all

# Run SQL benchmarks (Track 1)
[group('benchmarks')]
bench-sql *ARGS:
    kiroku-store/bench/sql/run_benchmarks.sh {{ARGS}}

# Capture a fresh kiroku-store benchmark baseline (overwrites baseline.csv)
[group('benchmarks')]
bench-baseline:
    @mkdir -p kiroku-store/bench/results
    @touch kiroku-store/bench/results/baseline.csv
    cabal bench kiroku-store:kiroku-store-bench \
        --benchmark-options="--csv $PWD/kiroku-store/bench/results/baseline.csv"
    @echo "Baseline written to kiroku-store/bench/results/baseline.csv"
    @echo "Review the change before committing — see docs/BENCH-REGRESSION.md"

# Run benchmarks and compare to baseline; fail if any benchmark is >10% slower
[group('benchmarks')]
bench-regression:
    just bench-regression-threshold 10

# Verify every historical benchmark has exactly one baseline row
[group('benchmarks')]
bench-baseline-check:
    cabal build kiroku-store:kiroku-store-bench
    kiroku-store/bench/check-baseline-coverage.sh

# Run benchmarks against baseline with a custom slowdown threshold (percent)
[group('benchmarks')]
bench-regression-threshold THRESHOLD:
    @if [ ! -s kiroku-store/bench/results/baseline.csv ]; then \
        echo "kiroku-store/bench/results/baseline.csv is empty or missing — capture one with 'just bench-baseline'"; \
        exit 1; \
    fi
    just bench-baseline-check
    cabal bench kiroku-store:kiroku-store-bench \
        --benchmark-options="--baseline $PWD/kiroku-store/bench/results/baseline.csv --fail-if-slower {{THRESHOLD}}"

# Re-run a single benchmark against baseline; pattern matches tasty-bench's --pattern
[group('benchmarks')]
bench-regression-pattern PATTERN:
    just bench-baseline-check
    cabal bench kiroku-store:kiroku-store-bench \
        --benchmark-options="--baseline $PWD/kiroku-store/bench/results/baseline.csv --fail-if-slower 10 --pattern {{PATTERN}}"

# Compare historical timings without failing on timing movement
[group('benchmarks')]
perf-telemetry:
    just bench-baseline-check
    cabal bench kiroku-store:kiroku-store-bench \
        --benchmark-options="--baseline $PWD/kiroku-store/bench/results/baseline.csv"

# Run deterministic performance invariants
[group('benchmarks')]
perf-structure:
    cabal test kiroku-store:kiroku-store-test \
        --test-show-details=direct \
        --test-options='--match "performance structure"'

# Compare production appendMultiStream with the sequential control
[group('benchmarks')]
perf-workload-gate:
    cabal bench kiroku-store:kiroku-store-bench-workload-gate \
        --benchmark-options="--stdev 5"

# Run the authoritative structural and controlled workload gates
[group('benchmarks')]
perf-check:
    just perf-structure
    just perf-workload-gate

# --- Docs ---

# Validate the OKF capability catalog against its pinned profile
[group('docs')]
capabilities-validate:
    mori validate
    okf validate docs/capabilities --profile docs/capabilities/profile.dhall \
        --profile-enforce --log-enforce
    okf graph docs/capabilities > /dev/null

# Validate the OKF architecture-decision bundle against its pinned profile
[group('docs')]
adr-validate:
    mori validate
    okf validate docs/adr --profile docs/adr/profile.dhall \
        --profile-enforce --log-enforce
    okf graph docs/adr > /dev/null

# --- Nix ---

# Build via nix
[group('nix')]
nix-build:
    nix build .#kiroku-store

# Run all nix checks
[group('nix')]
nix-check:
    nix flake check

# Format all files
[group('nix')]
fmt:
    nix fmt
