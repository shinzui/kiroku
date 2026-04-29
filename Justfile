# Kiroku development commands

# --- Services ---

# Start PostgreSQL via process-compose
up:
    process-compose up -D

# Stop all services
down:
    process-compose down

# --- Database ---

# Create the kiroku database if it doesn't exist
create-database:
    @psql -lqt | cut -d \| -f 1 | grep -qw kiroku || createdb kiroku
    @echo "Database 'kiroku' ready"

# Initialize the schema (apply schema.sql)
init-schema:
    psql -d kiroku -f kiroku-store/sql/schema.sql

# Drop and recreate the database
reset-database:
    dropdb --if-exists kiroku
    createdb kiroku
    just init-schema

# Open a psql session
psql:
    psql -d kiroku

# Truncate postgres logs
truncate-logs:
    truncate -s 0 $PGLOG

# --- Build ---

# Build the project
build:
    cabal build all

# Run tests
test:
    cabal test all

# Run benchmarks
bench:
    cabal bench all

# Run SQL benchmarks (Track 1)
bench-sql *ARGS:
    kiroku-store/bench/sql/run_benchmarks.sh {{ARGS}}

# Capture a fresh kiroku-store benchmark baseline (overwrites baseline.csv)
bench-baseline:
    @mkdir -p kiroku-store/bench/results
    @touch kiroku-store/bench/results/baseline.csv
    cabal bench kiroku-store:kiroku-store-bench \
        --benchmark-options="--csv $PWD/kiroku-store/bench/results/baseline.csv"
    @echo "Baseline written to kiroku-store/bench/results/baseline.csv"
    @echo "Review the change before committing — see docs/BENCH-REGRESSION.md"

# Run benchmarks and compare to baseline; fail if any benchmark is >10% slower
bench-regression:
    just bench-regression-threshold 10

# Run benchmarks against baseline with a custom slowdown threshold (percent)
bench-regression-threshold THRESHOLD:
    @if [ ! -s kiroku-store/bench/results/baseline.csv ]; then \
        echo "kiroku-store/bench/results/baseline.csv is empty or missing — capture one with 'just bench-baseline'"; \
        exit 1; \
    fi
    cabal bench kiroku-store:kiroku-store-bench \
        --benchmark-options="--baseline $PWD/kiroku-store/bench/results/baseline.csv --fail-if-slower {{THRESHOLD}}"

# Re-run a single benchmark against baseline; pattern matches tasty-bench's --pattern
bench-regression-pattern PATTERN:
    cabal bench kiroku-store:kiroku-store-bench \
        --benchmark-options="--baseline $PWD/kiroku-store/bench/results/baseline.csv --fail-if-slower 10 --pattern {{PATTERN}}"

# --- Nix ---

# Build via nix
nix-build:
    nix build .#kiroku-store

# Run all nix checks
nix-check:
    nix flake check

# Format all files
fmt:
    nix fmt
