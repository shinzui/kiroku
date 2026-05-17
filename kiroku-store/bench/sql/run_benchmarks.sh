#!/usr/bin/env bash
set -euo pipefail

# Kiroku SQL Benchmark Harness
# Runs Track 1 SQL benchmarks against PostgreSQL using pgbench.
#
# Usage:
#   ./run_benchmarks.sh              # Run all benchmarks
#   ./run_benchmarks.sh 1 3 5        # Run specific benchmarks
#   ./run_benchmarks.sh --help       # Show usage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB="${KIROKU_BENCH_DB:-kiroku}"
RESULTS_DIR="${SCRIPT_DIR}/../../bench/results"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULTS_FILE="${RESULTS_DIR}/sql_bench_${TIMESTAMP}.txt"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Extract TPS from pgbench output (portable, no grep -P)
extract_tps() {
    echo "$1" | sed -n 's/.*tps = \([0-9.]*\).*/\1/p' | head -1
}

# Extract average latency from pgbench output
extract_latency() {
    echo "$1" | sed -n 's/.*latency average = \([0-9.]*\).*/\1/p' | head -1
}

usage() {
    echo "Usage: $0 [BENCHMARK_NUMBERS...]"
    echo ""
    echo "Benchmarks:"
    echo "  1  Single-stream sequential appends (1 event/CTE, 10K iterations)"
    echo "  2  Batched appends (10, 100, 1000 events per CTE)"
    echo "  3  Cross-stream concurrent appends (4-64 connections)"
    echo "  4  Cross-stream concurrent batched appends (4-32 connections)"
    echo "  5  Read throughput (stream, \$all, category)"
    echo "  6  Mixed read/write (8 writers + 8 readers)"
    echo ""
    echo "Environment:"
    echo "  KIROKU_BENCH_DB   Database name (default: kiroku)"
    exit 0
}

# Parse args
BENCHMARKS=()
for arg in "$@"; do
    case "$arg" in
        --help|-h) usage ;;
        [1-6]) BENCHMARKS+=("$arg") ;;
        *) echo "Unknown argument: $arg"; usage ;;
    esac
done

# Default: run all
if [ ${#BENCHMARKS[@]} -eq 0 ]; then
    BENCHMARKS=(1 2 3 4 5 6)
fi

# Check prerequisites
check_prereqs() {
    if ! command -v pgbench &>/dev/null; then
        echo -e "${RED}Error: pgbench not found. Install PostgreSQL client tools.${NC}"
        exit 1
    fi

    if ! psql -d "$DB" -c "SELECT 1" &>/dev/null; then
        echo -e "${RED}Error: Cannot connect to database '$DB'.${NC}"
        echo "Make sure PostgreSQL is running (just up) and the database exists (just create-database && just init-schema)."
        exit 1
    fi

    # Verify schema is applied
    if ! psql -d "$DB" -tAc "SELECT 1 FROM streams WHERE stream_id = 0" 2>/dev/null | grep -q 1; then
        echo -e "${RED}Error: Schema not initialized. Run: just init-schema${NC}"
        exit 1
    fi

    if ! psql -d "$DB" -tAc "SELECT to_regprocedure('uuidv7()') IS NOT NULL" 2>/dev/null | grep -q t; then
        echo -e "${RED}Error: uuidv7() is not available. Re-run schema initialization: just init-schema${NC}"
        exit 1
    fi
}

# Reset database state for a clean benchmark
reset_state() {
    echo -e "${BLUE}Resetting benchmark data...${NC}"
    psql -d "$DB" -f "${SCRIPT_DIR}/reset.sql" -q
}

# Ensure benchmark streams exist
ensure_streams() {
    psql -d "$DB" -f "${SCRIPT_DIR}/ensure_streams.sql" -q
}

# Compute percentiles from pgbench log files
# Args: log_prefix, label
compute_percentiles() {
    local log_prefix="$1"
    local label="$2"

    # pgbench --log creates files like prefix.CLIENT_ID
    local log_files
    log_files=$(ls "${log_prefix}".* 2>/dev/null || true)

    if [ -z "$log_files" ]; then
        return
    fi

    # Column 3 in pgbench log is latency in microseconds
    local p50 p95 p99
    local all_latencies
    all_latencies=$(cat ${log_prefix}.* | awk '{print $3}' | sort -n)
    local count
    count=$(echo "$all_latencies" | wc -l | tr -d ' ')

    if [ "$count" -gt 0 ]; then
        p50=$(echo "$all_latencies" | awk "NR==int(${count}*0.50){print \$1}")
        p95=$(echo "$all_latencies" | awk "NR==int(${count}*0.95){print \$1}")
        p99=$(echo "$all_latencies" | awk "NR==int(${count}*0.99){print \$1}")

        # Convert microseconds to milliseconds
        p50=$(echo "scale=3; ${p50:-0} / 1000" | bc)
        p95=$(echo "scale=3; ${p95:-0} / 1000" | bc)
        p99=$(echo "scale=3; ${p99:-0} / 1000" | bc)

        echo -e "    ${YELLOW}Percentiles — p50: ${p50}ms  p95: ${p95}ms  p99: ${p99}ms${NC}"
        echo "  Percentiles: p50=${p50}ms p95=${p95}ms p99=${p99}ms" >> "$RESULTS_FILE"
    fi

    # Clean up log files
    rm -f ${log_prefix}.* 2>/dev/null || true
}

# --- Benchmark implementations ---

bench_1() {
    echo -e "\n${BOLD}${BLUE}=== Benchmark 1: Single-stream sequential appends ===${NC}"
    echo "=== Benchmark 1: Single-stream sequential appends ===" >> "$RESULTS_FILE"

    reset_state
    ensure_streams

    local log_prefix="${RESULTS_DIR}/pgbench_log_${TIMESTAMP}_b1"

    echo -e "  ${BOLD}1 event/CTE × 10,000 iterations × 1 connection${NC}"
    local output
    output=$(pgbench -n -f "${SCRIPT_DIR}/bench_append_single.sql" \
        -t 10000 -c 1 -j 1 \
        --log --log-prefix="${log_prefix}" \
        "$DB" 2>&1) || true

    local tps latency_avg
    tps=$(extract_tps "$output")
    tps=${tps:-N/A}
    latency_avg=$(extract_latency "$output")
    latency_avg=${latency_avg:-N/A}

    echo -e "    ${GREEN}TPS: ${tps}  |  Avg latency: ${latency_avg} ms${NC}"
    echo "$output" >> "$RESULTS_FILE"

    compute_percentiles "$log_prefix" "Bench 1"
    echo "" >> "$RESULTS_FILE"
}

bench_2() {
    echo -e "\n${BOLD}${BLUE}=== Benchmark 2: Batched appends ===${NC}"
    echo "=== Benchmark 2: Batched appends ===" >> "$RESULTS_FILE"

    for batch_size in 10 100 1000; do
        reset_state
        ensure_streams

        local txns=$((10000 / batch_size))
        local log_prefix="${RESULTS_DIR}/pgbench_log_${TIMESTAMP}_b2_${batch_size}"

        echo -e "  ${BOLD}${batch_size} events/CTE × ${txns} iterations × 1 connection${NC}"
        local output
        output=$(pgbench -n -f "${SCRIPT_DIR}/bench_append_batch_${batch_size}.sql" \
            -t "$txns" -c 1 -j 1 \
            --log --log-prefix="${log_prefix}" \
            "$DB" 2>&1) || true

        local tps latency_avg
        tps=$(echo "$output" | grep -oP 'tps = \K[0-9.]+(?= \(without)' || echo "$output" | grep -oP 'tps = \K[0-9.]+' || echo "N/A")
        latency_avg=$(echo "$output" | grep -oP 'latency average = \K[0-9.]+' || echo "N/A")
        local events_per_sec
        if [ "$tps" != "N/A" ]; then
            events_per_sec=$(echo "scale=0; ${tps} * ${batch_size}" | bc)
        else
            events_per_sec="N/A"
        fi

        echo -e "    ${GREEN}TPS: ${tps}  |  Events/s: ${events_per_sec}  |  Avg latency: ${latency_avg} ms${NC}"
        echo "  batch_size=${batch_size} tps=${tps} events/s=${events_per_sec}" >> "$RESULTS_FILE"
        echo "$output" >> "$RESULTS_FILE"

        compute_percentiles "$log_prefix" "Bench 2 (batch=${batch_size})"
        echo "" >> "$RESULTS_FILE"
    done
}

bench_3() {
    echo -e "\n${BOLD}${BLUE}=== Benchmark 3: Cross-stream concurrent appends (\$all contention) ===${NC}"
    echo "=== Benchmark 3: Cross-stream concurrent appends ===" >> "$RESULTS_FILE"

    for conc in 4 8 16 32 64; do
        reset_state
        ensure_streams

        local log_prefix="${RESULTS_DIR}/pgbench_log_${TIMESTAMP}_b3_c${conc}"

        echo -e "  ${BOLD}1 event/CTE × 1,000 iterations × ${conc} connections${NC}"
        local output
        output=$(pgbench -n -f "${SCRIPT_DIR}/bench_append_concurrent.sql" \
            -t 1000 -c "$conc" -j "$conc" \
            --log --log-prefix="${log_prefix}" \
            "$DB" 2>&1) || true

        local tps latency_avg
        tps=$(echo "$output" | grep -oP 'tps = \K[0-9.]+(?= \(without)' || echo "$output" | grep -oP 'tps = \K[0-9.]+' || echo "N/A")
        latency_avg=$(echo "$output" | grep -oP 'latency average = \K[0-9.]+' || echo "N/A")

        echo -e "    ${GREEN}TPS: ${tps}  |  Avg latency: ${latency_avg} ms${NC}"
        echo "  connections=${conc} tps=${tps} avg_latency=${latency_avg}ms" >> "$RESULTS_FILE"
        echo "$output" >> "$RESULTS_FILE"

        compute_percentiles "$log_prefix" "Bench 3 (c=${conc})"
        echo "" >> "$RESULTS_FILE"
    done
}

bench_4() {
    echo -e "\n${BOLD}${BLUE}=== Benchmark 4: Cross-stream concurrent batched appends ===${NC}"
    echo "=== Benchmark 4: Cross-stream concurrent batched appends ===" >> "$RESULTS_FILE"

    for conc in 4 8 16 32; do
        reset_state
        ensure_streams

        local log_prefix="${RESULTS_DIR}/pgbench_log_${TIMESTAMP}_b4_c${conc}"

        echo -e "  ${BOLD}10 events/CTE × 1,000 iterations × ${conc} connections${NC}"
        local output
        output=$(pgbench -n -f "${SCRIPT_DIR}/bench_append_concurrent_batch.sql" \
            -t 1000 -c "$conc" -j "$conc" \
            --log --log-prefix="${log_prefix}" \
            "$DB" 2>&1) || true

        local tps latency_avg
        tps=$(echo "$output" | grep -oP 'tps = \K[0-9.]+(?= \(without)' || echo "$output" | grep -oP 'tps = \K[0-9.]+' || echo "N/A")
        latency_avg=$(echo "$output" | grep -oP 'latency average = \K[0-9.]+' || echo "N/A")
        local events_per_sec
        if [ "$tps" != "N/A" ]; then
            events_per_sec=$(echo "scale=0; ${tps} * 10" | bc)
        else
            events_per_sec="N/A"
        fi

        echo -e "    ${GREEN}TPS: ${tps}  |  Events/s: ${events_per_sec}  |  Avg latency: ${latency_avg} ms${NC}"
        echo "  connections=${conc} tps=${tps} events/s=${events_per_sec}" >> "$RESULTS_FILE"
        echo "$output" >> "$RESULTS_FILE"

        compute_percentiles "$log_prefix" "Bench 4 (c=${conc})"
        echo "" >> "$RESULTS_FILE"
    done
}

bench_5() {
    echo -e "\n${BOLD}${BLUE}=== Benchmark 5: Read throughput ===${NC}"
    echo "=== Benchmark 5: Read throughput ===" >> "$RESULTS_FILE"

    # Setup: populate read data
    echo -e "  ${BLUE}Populating 100K events for read benchmarks...${NC}"
    psql -d "$DB" -f "${SCRIPT_DIR}/reset.sql" -q
    psql -d "$DB" -f "${SCRIPT_DIR}/setup.sql" -q
    echo -e "  ${GREEN}Setup complete.${NC}"

    # 5a: Stream read
    local log_prefix="${RESULTS_DIR}/pgbench_log_${TIMESTAMP}_b5_stream"

    echo -e "\n  ${BOLD}5a: Stream read (100-event pages × 5,000 iterations)${NC}"
    local output
    output=$(pgbench -n -f "${SCRIPT_DIR}/bench_read_stream.sql" \
        -t 5000 -c 1 -j 1 \
        --log --log-prefix="${log_prefix}" \
        "$DB" 2>&1) || true

    local tps latency_avg
    tps=$(extract_tps "$output")
    tps=${tps:-N/A}
    latency_avg=$(extract_latency "$output")
    latency_avg=${latency_avg:-N/A}

    echo -e "    ${GREEN}Pages/s: ${tps}  |  Avg latency: ${latency_avg} ms${NC}"
    echo "  stream_read tps=${tps}" >> "$RESULTS_FILE"
    echo "$output" >> "$RESULTS_FILE"
    compute_percentiles "$log_prefix" "Stream read"
    echo "" >> "$RESULTS_FILE"

    # 5b: $all read
    log_prefix="${RESULTS_DIR}/pgbench_log_${TIMESTAMP}_b5_all"

    echo -e "  ${BOLD}5b: \$all read (100-event pages × 5,000 iterations)${NC}"
    output=$(pgbench -n -f "${SCRIPT_DIR}/bench_read_all.sql" \
        -t 5000 -c 1 -j 1 \
        --log --log-prefix="${log_prefix}" \
        "$DB" 2>&1) || true

    tps=$(extract_tps "$output")
    tps=${tps:-N/A}
    latency_avg=$(extract_latency "$output")
    latency_avg=${latency_avg:-N/A}

    echo -e "    ${GREEN}Pages/s: ${tps}  |  Avg latency: ${latency_avg} ms${NC}"
    echo "  all_read tps=${tps}" >> "$RESULTS_FILE"
    echo "$output" >> "$RESULTS_FILE"
    compute_percentiles "$log_prefix" "\$all read"
    echo "" >> "$RESULTS_FILE"

    # 5c: Category read
    log_prefix="${RESULTS_DIR}/pgbench_log_${TIMESTAMP}_b5_category"

    echo -e "  ${BOLD}5c: Category read (100-event pages × 1,000 iterations)${NC}"
    output=$(pgbench -n -f "${SCRIPT_DIR}/bench_read_category.sql" \
        -t 1000 -c 1 -j 1 \
        --log --log-prefix="${log_prefix}" \
        "$DB" 2>&1) || true

    tps=$(extract_tps "$output")
    tps=${tps:-N/A}
    latency_avg=$(extract_latency "$output")
    latency_avg=${latency_avg:-N/A}

    echo -e "    ${GREEN}Pages/s: ${tps}  |  Avg latency: ${latency_avg} ms${NC}"
    echo "  category_read tps=${tps}" >> "$RESULTS_FILE"
    echo "$output" >> "$RESULTS_FILE"
    compute_percentiles "$log_prefix" "Category read"
    echo "" >> "$RESULTS_FILE"
}

bench_6() {
    echo -e "\n${BOLD}${BLUE}=== Benchmark 6: Mixed read/write ===${NC}"
    echo "=== Benchmark 6: Mixed read/write ===" >> "$RESULTS_FILE"

    # Use data from bench 5 setup (or re-populate)
    if ! psql -d "$DB" -tAc "SELECT count(*) > 0 FROM events" 2>/dev/null | grep -q t; then
        echo -e "  ${BLUE}Populating read data...${NC}"
        psql -d "$DB" -f "${SCRIPT_DIR}/setup.sql" -q
    fi

    # Ensure writer streams exist
    ensure_streams

    local write_log="${RESULTS_DIR}/pgbench_log_${TIMESTAMP}_b6_write"
    local read_log="${RESULTS_DIR}/pgbench_log_${TIMESTAMP}_b6_read"

    echo -e "  ${BOLD}8 writers (10 events/batch) + 8 readers (100-event pages)${NC}"

    # Run writers and readers concurrently
    pgbench -n -f "${SCRIPT_DIR}/bench_mixed_write.sql" \
        -t 1000 -c 8 -j 8 \
        --log --log-prefix="${write_log}" \
        "$DB" > "${RESULTS_DIR}/mixed_write_output_${TIMESTAMP}.txt" 2>&1 &
    local writer_pid=$!

    pgbench -n -f "${SCRIPT_DIR}/bench_mixed_read.sql" \
        -t 2000 -c 8 -j 8 \
        --log --log-prefix="${read_log}" \
        "$DB" > "${RESULTS_DIR}/mixed_read_output_${TIMESTAMP}.txt" 2>&1 &
    local reader_pid=$!

    # Wait for both
    local write_exit=0 read_exit=0
    wait "$writer_pid" || write_exit=$?
    wait "$reader_pid" || read_exit=$?

    # Report writer results
    echo -e "\n  ${BOLD}Writers:${NC}"
    if [ -f "${RESULTS_DIR}/mixed_write_output_${TIMESTAMP}.txt" ]; then
        local write_output
        write_output=$(cat "${RESULTS_DIR}/mixed_write_output_${TIMESTAMP}.txt")
        local write_tps
        write_tps=$(extract_tps "$write_output")
        write_tps=${write_tps:-N/A}
        local write_latency
        write_latency=$(extract_latency "$write_output")
        write_latency=${write_latency:-N/A}
        local write_events
        if [ "$write_tps" != "N/A" ]; then
            write_events=$(echo "scale=0; ${write_tps} * 10" | bc)
        else
            write_events="N/A"
        fi

        echo -e "    ${GREEN}TPS: ${write_tps}  |  Events/s: ${write_events}  |  Avg latency: ${write_latency} ms${NC}"
        echo "  writers: tps=${write_tps} events/s=${write_events}" >> "$RESULTS_FILE"
        echo "$write_output" >> "$RESULTS_FILE"
    fi
    compute_percentiles "$write_log" "Mixed writers"

    # Report reader results
    echo -e "\n  ${BOLD}Readers:${NC}"
    if [ -f "${RESULTS_DIR}/mixed_read_output_${TIMESTAMP}.txt" ]; then
        local read_output
        read_output=$(cat "${RESULTS_DIR}/mixed_read_output_${TIMESTAMP}.txt")
        local read_tps
        read_tps=$(extract_tps "$read_output")
        read_tps=${read_tps:-N/A}
        local read_latency
        read_latency=$(extract_latency "$read_output")
        read_latency=${read_latency:-N/A}

        echo -e "    ${GREEN}Pages/s: ${read_tps}  |  Avg latency: ${read_latency} ms${NC}"
        echo "  readers: tps=${read_tps}" >> "$RESULTS_FILE"
        echo "$read_output" >> "$RESULTS_FILE"
    fi
    compute_percentiles "$read_log" "Mixed readers"

    # Clean up temp files
    rm -f "${RESULTS_DIR}/mixed_write_output_${TIMESTAMP}.txt" \
          "${RESULTS_DIR}/mixed_read_output_${TIMESTAMP}.txt" 2>/dev/null || true

    echo "" >> "$RESULTS_FILE"
}

# --- Main ---

echo -e "${BOLD}${BLUE}"
echo "╔══════════════════════════════════════════════════╗"
echo "║       Kiroku SQL Benchmarks (Track 1)            ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

check_prereqs

mkdir -p "$RESULTS_DIR"
echo "Kiroku SQL Benchmark Results — $(date)" > "$RESULTS_FILE"
echo "Database: ${DB}" >> "$RESULTS_FILE"
echo "PostgreSQL: $(psql -d "$DB" -tAc 'SELECT version()')" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"

echo -e "Database: ${BOLD}${DB}${NC}"
echo -e "Results:  ${BOLD}${RESULTS_FILE}${NC}"
echo -e "Benchmarks to run: ${BOLD}${BENCHMARKS[*]}${NC}"

for bench in "${BENCHMARKS[@]}"; do
    "bench_${bench}"
done

echo -e "\n${BOLD}${GREEN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║                 Benchmarks Complete               ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "Full results: ${BOLD}${RESULTS_FILE}${NC}"
