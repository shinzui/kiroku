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
    CODD_CONNECTION='dbname=kiroku' \
    CODD_MIGRATION_DIRS=unused-for-embedded-migrations \
    CODD_EXPECTED_SCHEMA_DIR=unused-for-unverified-embedded-migrations \
    CODD_SCHEMAS=kiroku \
    cabal run kiroku-store-migrate

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

# Run benchmarks against baseline with a custom slowdown threshold (percent)
[group('benchmarks')]
bench-regression-threshold THRESHOLD:
    @if [ ! -s kiroku-store/bench/results/baseline.csv ]; then \
        echo "kiroku-store/bench/results/baseline.csv is empty or missing — capture one with 'just bench-baseline'"; \
        exit 1; \
    fi
    cabal bench kiroku-store:kiroku-store-bench \
        --benchmark-options="--baseline $PWD/kiroku-store/bench/results/baseline.csv --fail-if-slower {{THRESHOLD}}"

# Re-run a single benchmark against baseline; pattern matches tasty-bench's --pattern
[group('benchmarks')]
bench-regression-pattern PATTERN:
    cabal bench kiroku-store:kiroku-store-bench \
        --benchmark-options="--baseline $PWD/kiroku-store/bench/results/baseline.csv --fail-if-slower 10 --pattern {{PATTERN}}"

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
