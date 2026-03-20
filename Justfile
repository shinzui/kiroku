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
