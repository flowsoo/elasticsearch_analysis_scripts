#!/usr/bin/env bash

# Elasticsearch / Kibana Load Diagnostic
# Read-only diagnostics - does not modify the system.

set +e

ES_URL="${ES_URL:-http://localhost:9200}"
LOG_LINES=30

hr() {
    echo
    echo "======================================================================"
    echo "$1"
    echo "======================================================================"
}

run_cmd() {
    echo
    echo "+ $*"
    "$@" 2>&1
}

echo
echo "######################################################################"
echo "# Elasticsearch / Kibana / NRPE Load Diagnostic"
echo "# Host: $(hostname)"
echo "# Date: $(date)"
echo "######################################################################"

# ----------------------------------------------------------------------
hr "1. SYSTEM / LOAD"
# ----------------------------------------------------------------------

run_cmd uptime

echo
echo "CPU / logical processors:"
run_cmd nproc

echo
echo "CPU information:"
lscpu 2>/dev/null | grep -E \
    '^(CPU\(s\)|On-line CPU|Thread\(s\) per core|Core\(s\) per socket|Socket\(s\)|Model name)' \
    || true

echo
echo "Load averages:"
cat /proc/loadavg

echo
echo "Interpretation:"
LOAD1=$(awk '{print $1}' /proc/loadavg)
CPUS=$(nproc)

awk -v load="$LOAD1" -v cpu="$CPUS" '
BEGIN {
    ratio=load/cpu
    printf "  1-min load: %.2f\n", load
    printf "  CPUs:       %d\n", cpu
    printf "  Load/CPU:   %.2f\n", ratio

    if (ratio >= 2)
        print "  WARNING: load is more than 2x the CPU count"
    else if (ratio >= 1)
        print "  WARNING: load is at/above CPU capacity"
    else
        print "  OK: load is below CPU capacity"
}
'

# ----------------------------------------------------------------------
hr "2. MEMORY / SWAP"
# ----------------------------------------------------------------------

run_cmd free -h

echo
echo "Swap:"
swapon --show 2>/dev/null || echo "No swap information available"

echo
echo "Memory pressure:"
cat /proc/meminfo | grep -E \
    'MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|Dirty|Writeback'

# ----------------------------------------------------------------------
hr "3. VMSTAT - CPU / MEMORY / I/O"
# ----------------------------------------------------------------------

run_cmd vmstat 1 5

# ----------------------------------------------------------------------
hr "4. DISK / I/O"
# ----------------------------------------------------------------------

if command -v iostat >/dev/null 2>&1; then
    run_cmd iostat -xz 1 5
else
    echo "iostat is NOT installed."
    echo
    echo "Install package:"
    echo "  Debian/Ubuntu: apt install sysstat"
    echo "  RHEL/CentOS:   yum install sysstat"
fi

echo
echo "Filesystem usage:"
run_cmd df -hT

echo
echo "Inode usage:"
run_cmd df -ih

# ----------------------------------------------------------------------
hr "5. TOP CPU PROCESSES"
# ----------------------------------------------------------------------

ps -eo pid,ppid,user,stat,%cpu,%mem,etime,cmd --sort=-%cpu | head -21

# ----------------------------------------------------------------------
hr "6. TOP MEMORY PROCESSES"
# ----------------------------------------------------------------------

ps -eo pid,ppid,user,stat,%cpu,%mem,etime,cmd --sort=-%mem | head -21

# ----------------------------------------------------------------------
hr "7. ELASTICSEARCH PROCESS"
# ----------------------------------------------------------------------

echo "Elasticsearch processes:"
pgrep -a -f 'elasticsearch' 2>/dev/null || echo "No Elasticsearch process found"

echo
echo "Java processes:"
ps -eo pid,ppid,user,%cpu,%mem,etime,cmd --sort=-%cpu \
    | grep -i '[j]ava' \
    | head -15

# ----------------------------------------------------------------------
hr "8. ELASTICSEARCH CONNECTIVITY"
# ----------------------------------------------------------------------

if command -v curl >/dev/null 2>&1; then

    echo "Testing: $ES_URL"

    ES_STATUS=$(curl -sS --connect-timeout 3 --max-time 10 \
        -o /dev/null -w '%{http_code}' "$ES_URL" 2>/dev/null)

    echo "HTTP status: $ES_STATUS"

    if [[ "$ES_STATUS" =~ ^2 ]]; then
        echo "Elasticsearch is reachable."
    else
        echo "WARNING: Elasticsearch did not return a normal 2xx response."
    fi

else
    echo "curl is not installed."
fi

# ----------------------------------------------------------------------
hr "9. ELASTICSEARCH CLUSTER HEALTH"
# ----------------------------------------------------------------------

if command -v curl >/dev/null 2>&1; then
    curl -sS --connect-timeout 3 --max-time 10 \
        "$ES_URL/_cluster/health?pretty" 2>&1 \
        || echo "Could not query Elasticsearch cluster health."
fi

# ----------------------------------------------------------------------
hr "10. ELASTICSEARCH NODES"
# ----------------------------------------------------------------------

if command -v curl >/dev/null 2>&1; then
    curl -sS --connect-timeout 3 --max-time 10 \
        "$ES_URL/_cat/nodes?v" 2>&1 \
        || echo "Could not query Elasticsearch nodes."
fi

# ----------------------------------------------------------------------
hr "11. ELASTICSEARCH NODE RESOURCE USAGE"
# ----------------------------------------------------------------------

if command -v curl >/dev/null 2>&1; then
    curl -sS --connect-timeout 3 --max-time 15 \
        "$ES_URL/_cat/nodes?v&h=name,ip,node.role,master,heap.percent,ram.percent,cpu,load_1m,load_5m,load_15m,disk.used_percent" \
        2>&1 \
        || echo "Could not query Elasticsearch node statistics."
fi

# ----------------------------------------------------------------------
hr "12. ELASTICSEARCH HOT THREADS"
# ----------------------------------------------------------------------

if command -v curl >/dev/null 2>&1; then
    curl -sS --connect-timeout 3 --max-time 15 \
        "$ES_URL/_nodes/hot_threads" 2>&1 \
        | head -200 \
        || echo "Could not retrieve Elasticsearch hot threads."
fi

# ----------------------------------------------------------------------
hr "13. ELASTICSEARCH THREAD POOLS"
# ----------------------------------------------------------------------

if command -v curl >/dev/null 2>&1; then
    curl -sS --connect-timeout 3 --max-time 15 \
        "$ES_URL/_cat/thread_pool?v" 2>&1 \
        || echo "Could not query Elasticsearch thread pools."
fi

# ----------------------------------------------------------------------
hr "14. ELASTICSEARCH INDICES"
# ----------------------------------------------------------------------

if command -v curl >/dev/null 2>&1; then
    curl -sS --connect-timeout 3 --max-time 15 \
        "$ES_URL/_cat/indices?v&s=store.size:desc" 2>&1 \
        | head -100 \
        || echo "Could not query Elasticsearch indices."
fi

# ----------------------------------------------------------------------
hr "15. ELASTICSEARCH JVM / GC"
# ----------------------------------------------------------------------

if command -v curl >/dev/null 2>&1; then
    curl -sS --connect-timeout 3 --max-time 15 \
        "$ES_URL/_nodes/stats/jvm?pretty" 2>&1 \
        | head -250 \
        || echo "Could not query Elasticsearch JVM statistics."
fi

# ----------------------------------------------------------------------
hr "16. KIBANA SERVICE"
# ----------------------------------------------------------------------

if command -v systemctl >/dev/null 2>&1; then
    echo "Kibana service:"
    systemctl is-active kibana 2>&1
    systemctl is-enabled kibana 2>&1

    echo
    systemctl status kibana --no-pager -l 2>&1 | head -60
else
    echo "systemctl not available."
fi

# ----------------------------------------------------------------------
hr "17. KIBANA PROCESSES"
# ----------------------------------------------------------------------

pgrep -a -f 'kibana' 2>/dev/null || echo "No Kibana process found"

echo
echo "Top Kibana-related processes:"
ps -eo pid,ppid,user,%cpu,%mem,etime,cmd --sort=-%cpu \
    | grep -i '[k]ibana' \
    | head -15

# ----------------------------------------------------------------------
hr "18. KIBANA RECENT LOGS"
# ----------------------------------------------------------------------

if command -v journalctl >/dev/null 2>&1; then
    journalctl -u kibana --since "30 minutes ago" \
        --no-pager -n "$LOG_LINES" 2>&1
else
    echo "journalctl not available."
fi

# ----------------------------------------------------------------------
hr "19. ELASTICSEARCH SERVICE STATUS"
# ----------------------------------------------------------------------

if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active elasticsearch 2>&1

    echo
    systemctl status elasticsearch --no-pager -l 2>&1 | head -60
fi

# ----------------------------------------------------------------------
hr "20. RECENT SYSTEM ERRORS"
# ----------------------------------------------------------------------

if command -v journalctl >/dev/null 2>&1; then
    journalctl --since "30 minutes ago" \
        -p warning..alert \
        --no-pager 2>&1 | tail -100
else
    echo "journalctl not available."
fi

# ----------------------------------------------------------------------
hr "21. OOM / KERNEL EVENTS"
# ----------------------------------------------------------------------

echo "Possible OOM events:"
dmesg -T 2>/dev/null \
    | grep -iE 'out of memory|oom|killed process' \
    | tail -30 \
    || echo "No OOM messages found or dmesg access denied."

echo
echo "Disk / filesystem errors:"
dmesg -T 2>/dev/null \
    | grep -iE 'I/O error|blk_update_request|filesystem|ext4|xfs|nvme|scsi error' \
    | tail -30 \
    || echo "No obvious disk errors found or dmesg access denied."

# ----------------------------------------------------------------------
hr "22. QUICK SUMMARY"
# ----------------------------------------------------------------------

echo
echo "Load:"
uptime

echo
echo "CPU:"
echo "  CPUs: $(nproc)"
echo "  Load: $(cat /proc/loadavg | awk '{print $1, $2, $3}')"

echo
echo "Memory:"
free -h | head -3

echo
echo "Swap:"
free -h | tail -1

echo
echo "Elasticsearch:"
if curl -sS --connect-timeout 2 --max-time 5 \
    "$ES_URL/_cluster/health" >/dev/null 2>&1; then
    echo "  Reachable: YES"
else
    echo "  Reachable: NO"
fi

echo
echo "Kibana:"
if systemctl is-active --quiet kibana 2>/dev/null; then
    echo "  Service: ACTIVE"
else
    echo "  Service: NOT ACTIVE / unavailable"
fi

echo
echo "######################################################################"
echo "# Diagnostic complete"
echo "######################################################################"
echo
