#!/usr/bin/env bash

# ============================================================
# Elasticsearch Memory Diagnostic
# ============================================================
#
# READ-ONLY diagnostic script.
#
# Usage:
#   chmod +x es-memory-check.sh
#   ./es-memory-check.sh
#
# ============================================================


# ------------------------------------------------------------
# Elasticsearch connection
# ------------------------------------------------------------

ES_URL="https://your-elasticsearch-server:9200"
CURL_TIMEOUT=10


# ============================================================
# >>>>> PUT YOUR CURL AUTHENTICATION HERE <<<<<
# ============================================================
#
# Take the authentication/TLS OPTIONS from your working curl
# command and put them inside this block.
#
# For example, if your working command is:
#
# curl --cacert /path/to/ca.crt \
#      -H "Authorization: ApiKey ABC123" \
#      -X GET \
#      "https://your-elasticsearch-server:9200/_cluster/health"
#
# then put this here:
#
# ES_CURL_AUTH=(
#     --cacert "/path/to/ca.crt"
#     -H "Authorization: ApiKey ABC123"
#     -X GET
# )
#
# IMPORTANT:
# Do NOT put the Elasticsearch URL in this block.
# The URL belongs in ES_URL above.
#
# ============================================================

ES_CURL_AUTH=(
    --cacert "/PATH/TO/YOUR/CA/CERTIFICATE"
    -H "Authorization: ApiKey YOUR_API_KEY_HERE"
    -X GET
)


# ------------------------------------------------------------
# Elasticsearch curl wrapper
# ------------------------------------------------------------

es_curl() {
    curl -s \
        --max-time "$CURL_TIMEOUT" \
        "${ES_CURL_AUTH[@]}" \
        "$@"
}


# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

section() {
    echo
    echo "------------------------------------------------------------"
    echo " $1"
    echo "------------------------------------------------------------"
}

warn() {
    echo "[WARNING] $1"
}

good() {
    echo "[OK] $1"
}

info() {
    echo "[INFO] $1"
}

fail() {
    echo "[ERROR] $1"
}


# ------------------------------------------------------------
# Check dependencies
# ------------------------------------------------------------

section "Checking required commands"

for cmd in free ps curl awk sed grep sort; do
    if command -v "$cmd" >/dev/null 2>&1; then
        good "$cmd is available"
    else
        fail "$cmd is not installed"
    fi
done


# ------------------------------------------------------------
# System memory
# ------------------------------------------------------------

section "1. SYSTEM MEMORY"

FREE_OUTPUT="$(free -h)"
echo "$FREE_OUTPUT"

echo

MEM_TOTAL_KB="$(free | awk '/^Mem:/ {print $2}')"
MEM_USED_KB="$(free | awk '/^Mem:/ {print $3}')"
MEM_AVAILABLE_KB="$(free | awk '/^Mem:/ {print $7}')"

if [ -n "${MEM_TOTAL_KB:-}" ] && [ "$MEM_TOTAL_KB" -gt 0 ]; then
    USED_PERCENT=$((MEM_USED_KB * 100 / MEM_TOTAL_KB))
    AVAILABLE_PERCENT=$((MEM_AVAILABLE_KB * 100 / MEM_TOTAL_KB))

    echo "Memory used:       ${USED_PERCENT}%"
    echo "Memory available:  ${AVAILABLE_PERCENT}%"

    if [ "$AVAILABLE_PERCENT" -lt 10 ]; then
        warn "Less than 10% RAM is currently available."
        echo "      Significance: the server is under significant memory pressure."
    elif [ "$AVAILABLE_PERCENT" -lt 20 ]; then
        warn "Less than 20% RAM is currently available."
        echo "      Significance: worth investigating, although Linux cache may account for much of this."
    else
        good "A reasonable amount of memory is currently available."
    fi
fi

echo
echo "IMPORTANT:"
echo "  Linux deliberately uses unused RAM for filesystem cache."
echo "  Therefore 'used' RAM alone does NOT prove Elasticsearch has"
echo "  consumed the memory."


# ------------------------------------------------------------
# Elasticsearch Java process
# ------------------------------------------------------------

section "2. ELASTICSEARCH JAVA PROCESS MEMORY"

JAVA_PROCS="$(ps -eo pid,user,%mem,%cpu,rss,vsz,etime,cmd | grep '[j]ava' || true)"

if [ -z "$JAVA_PROCS" ]; then
    fail "No Java process found."
else
    echo "$JAVA_PROCS"
fi

echo

ES_PID="$(ps -eo pid,cmd | awk '/[e]lasticsearch/ && /java/ {print $1; exit}')"

if [ -n "${ES_PID:-}" ]; then

    ES_RSS_KB="$(ps -p "$ES_PID" -o rss= | awk '{print $1}')"
    ES_RSS_GB="$(awk "BEGIN {printf \"%.2f\", $ES_RSS_KB/1024/1024}")"

    echo "Elasticsearch PID:     $ES_PID"
    echo "Elasticsearch RSS:     ${ES_RSS_GB} GB"

    if [ "$MEM_TOTAL_KB" -gt 0 ]; then

        ES_PERCENT=$((ES_RSS_KB * 100 / MEM_TOTAL_KB))

        echo "Percentage of system RAM: ${ES_PERCENT}%"

        if [ "$ES_PERCENT" -gt 80 ]; then
            warn "Elasticsearch itself is consuming more than 80% of system RAM."
            echo "      Significance: this is NOT simply Linux filesystem cache."
            echo "      Investigate JVM heap, fielddata, caches, aggregations and shard count."

        elif [ "$ES_PERCENT" -gt 60 ]; then
            warn "Elasticsearch is consuming a substantial portion of system RAM."

        else
            good "Elasticsearch RSS is not consuming most system RAM."
            echo "      If system RAM is nevertheless near 100%, filesystem cache is likely important."
        fi
    fi

else
    warn "Could not automatically identify the Elasticsearch Java process."
fi


# ------------------------------------------------------------
# Elasticsearch connectivity
# ------------------------------------------------------------

section "3. ELASTICSEARCH CONNECTIVITY"

ES_INFO="$(es_curl "$ES_URL/" 2>/dev/null || true)"

if [ -z "$ES_INFO" ]; then

    fail "Could not connect to Elasticsearch at $ES_URL"

    echo
    echo "Check:"
    echo "  - ES_URL"
    echo "  - CA certificate path"
    echo "  - API key"
    echo "  - Elasticsearch availability"
    echo "  - network/firewall connectivity"

    ES_AVAILABLE=0

else

    good "Elasticsearch responded."

    echo "$ES_INFO" | sed 's/,/\n/g' | head -20

    ES_AVAILABLE=1
fi


# ------------------------------------------------------------
# JVM stats
# ------------------------------------------------------------

section "4. ELASTICSEARCH JVM / HEAP"

if [ "$ES_AVAILABLE" -eq 1 ]; then

    JVM_JSON="$(es_curl \
        "$ES_URL/_nodes/stats/jvm" \
        2>/dev/null || true)"

    if [ -z "$JVM_JSON" ]; then

        fail "Could not retrieve JVM statistics."

    else

        if command -v python3 >/dev/null 2>&1; then

            echo "$JVM_JSON" | python3 -c '
import sys, json

try:
    d=json.load(sys.stdin)

    for node_id,node in d.get("nodes",{}).items():

        name=node.get("name","unknown")
        jvm=node.get("jvm",{})
        mem=jvm.get("mem",{})

        heap_used=mem.get("heap_used_in_bytes",0)
        heap_max=mem.get("heap_max_in_bytes",0)
        heap_percent=mem.get("heap_used_percent",0)

        nonheap=mem.get("non_heap_used_in_bytes",0)

        print("Node:", name)
        print("  Heap used:       %.2f GB" % (heap_used/1024**3))
        print("  Heap max:        %.2f GB" % (heap_max/1024**3))
        print("  Heap usage:      %s%%" % heap_percent)
        print("  Non-heap memory: %.2f GB" % (nonheap/1024**3))

        if heap_percent >= 85:
            print("  [WARNING] Heap is very heavily utilised.")
            print("            Sustained high heap usage can cause GC pressure")
            print("            and eventually circuit-breaker/OOM problems.")

        elif heap_percent >= 70:
            print("  [WARNING] Heap usage is getting high.")

        else:
            print("  [OK] Heap usage is currently below 70%.")

        print()

except Exception as e:
    print("Could not parse JVM JSON:", e)
'

        else

            warn "python3 is not installed; displaying raw JVM response."
            echo "$JVM_JSON"

        fi
    fi
fi


# ------------------------------------------------------------
# Indices
# ------------------------------------------------------------

section "5. INDEX / SHARD OVERVIEW"

if [ "$ES_AVAILABLE" -eq 1 ]; then

    INDICES="$(es_curl \
        "$ES_URL/_cat/indices?v&bytes=gb&s=store.size:desc" \
        2>/dev/null || true)"

    if [ -z "$INDICES" ]; then

        warn "Could not retrieve index information."

    else

        echo "$INDICES"

        echo
        echo "Interpretation:"
        echo "  Large numbers of indices/shards can increase Elasticsearch's"
        echo "  baseline memory requirements."
        echo "  Time-based daily indices are particularly worth investigating."

    fi

    echo

    SHARDS="$(es_curl \
        "$ES_URL/_cat/shards?h=index,shard,prirep,state,docs,store&s=index" \
        2>/dev/null || true)"

    if [ -n "$SHARDS" ]; then

        SHARD_COUNT="$(echo "$SHARDS" | grep -c . || true)"

        echo "Total shard rows: $SHARD_COUNT"

        if [ "$SHARD_COUNT" -gt 1000 ]; then

            warn "More than 1000 shard entries detected."
            echo "      Significance: excessive shard counts can consume considerable heap."
            echo "      Improvement: consolidate indices/shards where practical."

        elif [ "$SHARD_COUNT" -gt 500 ]; then

            warn "More than 500 shard entries detected."
            echo "      Significance: shard overhead may be contributing to memory usage."

        else

            good "Shard count is not obviously excessive."

        fi
    fi
fi


# ------------------------------------------------------------
# Fielddata / query cache / request cache
# ------------------------------------------------------------

section "6. INDEX MEMORY USAGE / CACHES"

if [ "$ES_AVAILABLE" -eq 1 ]; then

    INDICES_STATS="$(es_curl \
        "$ES_URL/_nodes/stats/indices" \
        2>/dev/null || true)"

    if [ -n "$INDICES_STATS" ]; then

        if command -v python3 >/dev/null 2>&1; then

            echo "$INDICES_STATS" | python3 -c '
import sys,json

try:

    d=json.load(sys.stdin)

    for node_id,node in d.get("nodes",{}).items():

        name=node.get("name","unknown")
        indices=node.get("indices",{})

        fielddata=indices.get("fielddata",{})
        querycache=indices.get("query_cache",{})
        requestcache=indices.get("request_cache",{})
        segments=indices.get("segments",{})

        fd=fielddata.get("memory_size_in_bytes",0)
        qc=querycache.get("memory_size_in_bytes",0)
        rc=requestcache.get("memory_size_in_bytes",0)
        seg=segments.get("memory_in_bytes",0)

        print("Node:",name)
        print("  Fielddata:       %.2f GB" % (fd/1024**3))
        print("  Query cache:     %.2f GB" % (qc/1024**3))
        print("  Request cache:   %.2f GB" % (rc/1024**3))
        print("  Segment memory:  %.2f GB" % (seg/1024**3))

        if fd > 1024**3:

            print("  [WARNING] Fielddata exceeds 1 GB.")
            print("            Large fielddata usage can consume significant heap.")
            print("            Investigate aggregations/sorts on text fields.")

        elif fd > 512*1024**2:

            print("  [WARNING] Fielddata exceeds 512 MB.")

        if seg > 5*1024**3:

            print("  [WARNING] Segment memory exceeds 5 GB.")
            print("            Large numbers of segments/shards may be contributing.")

        print()

except Exception as e:
    print("Could not parse index statistics:",e)
'

        else

            warn "python3 is not installed; cannot parse index statistics."

        fi

    fi
fi


# ------------------------------------------------------------
# Circuit breakers
# ------------------------------------------------------------

section "7. CIRCUIT BREAKERS"

if [ "$ES_AVAILABLE" -eq 1 ]; then

    BREAKERS="$(es_curl \
        "$ES_URL/_nodes/stats/breaker" \
        2>/dev/null || true)"

    if [ -n "$BREAKERS" ]; then

        if command -v python3 >/dev/null 2>&1; then

            echo "$BREAKERS" | python3 -c '
import sys,json

try:

    d=json.load(sys.stdin)

    for node_id,node in d.get("nodes",{}).items():

        print("Node:",node.get("name","unknown"))

        breakers=node.get("breakers",{})

        for name,b in breakers.items():

            estimated=b.get("estimated_size_in_bytes",0)
            limit=b.get("limit_size_in_bytes",0)
            trips=b.get("tripped",0)

            print(
                "  %-20s estimated=%8.2f GB limit=%8.2f GB trips=%d"
                % (
                    name,
                    estimated/1024**3,
                    limit/1024**3,
                    trips
                )
            )

            if trips > 0:

                print("    [WARNING] This breaker has tripped.")
                print("              Queries may be requesting more memory than Elasticsearch allows.")

        print()

except Exception as e:
    print("Could not parse breaker statistics:",e)
'

        else

            warn "python3 is not installed; cannot parse breaker statistics."

        fi

    else

        warn "Could not retrieve circuit breaker statistics."

    fi
fi


# ------------------------------------------------------------
# Disk / index cache context
# ------------------------------------------------------------

section "8. FILESYSTEM / DISK CACHE CONTEXT"

df -hT | head -20

echo

echo "Linux filesystem cache is particularly relevant to Elasticsearch because"
echo "Lucene reads index segments from disk and Linux caches frequently accessed"
echo "files in RAM."

echo
echo "The 'available' column from 'free -h' is more useful than 'used' when"
echo "determining whether Linux is genuinely running out of memory."


# ------------------------------------------------------------
# Midnight / daily-index investigation
# ------------------------------------------------------------

section "9. LOOKING FOR DAILY / TIME-BASED INDICES"

if [ "$ES_AVAILABLE" -eq 1 ]; then

    INDEX_NAMES="$(es_curl \
        "$ES_URL/_cat/indices?h=index&s=index" \
        2>/dev/null || true)"

    if [ -n "$INDEX_NAMES" ]; then

        echo "$INDEX_NAMES" | grep -Ei \
            '20[0-9]{2}[.-][0-9]{2}[.-][0-9]{2}|[0-9]{8}|daily|day-|date-|logs-|logstash-|metrics-|filebeat-|metricbeat-' \
            | head -100

        MATCHES="$(echo "$INDEX_NAMES" | grep -Eic \
            '20[0-9]{2}[.-][0-9]{2}[.-][0-9]{2}|[0-9]{8}|daily|day-|date-|logs-|logstash-|metrics-|filebeat-|metricbeat-' \
            || true)"

        echo

        if [ "$MATCHES" -gt 0 ]; then

            warn "$MATCHES index names look potentially time-based."

            echo "      Significance: a midnight rollover/ILM operation may explain the"
            echo "      daily memory reset."

        else

            info "No obvious daily/time-based index naming pattern was detected."

        fi
    fi
fi


# ------------------------------------------------------------
# Elasticsearch settings
# ------------------------------------------------------------

section "10. IMPORTANT ELASTICSEARCH SETTINGS"

if [ "$ES_AVAILABLE" -eq 1 ]; then

    SETTINGS="$(es_curl \
        "$ES_URL/_cluster/settings?include_defaults=true&flat_settings=true" \
        2>/dev/null || true)"

    if [ -n "$SETTINGS" ]; then

        echo "$SETTINGS" | grep -Ei \
            '"(indices|search|indices.memory|fielddata|breaker|cluster.routing|indices.lifecycle|xpack)"' \
            | head -80 || true

    fi
fi


# ------------------------------------------------------------
# Final diagnosis
# ------------------------------------------------------------

section "11. OVERALL INTERPRETATION"

echo
echo "Based on the results above, consider these possibilities in this order:"
echo

echo "1. LINUX FILESYSTEM CACHE"
echo "   ----------------------------------------------------------"
echo "   If Elasticsearch RSS is relatively modest but system RAM"
echo "   approaches 100%, Linux may simply be caching Lucene index files."
echo
echo "   This is generally NORMAL."
echo "   Linux will reclaim that memory when applications need it."
echo

echo "2. JVM HEAP PRESSURE"
echo "   ----------------------------------------------------------"
echo "   If Elasticsearch heap is repeatedly >75-85%, investigate:"
echo "     - fielddata"
echo "     - aggregations"
echo "     - expensive searches"
echo "     - excessive shards"
echo "     - mappings"
echo "     - large numbers of indices"
echo "     - long-running searches"
echo
echo "   Increasing heap is not automatically the right solution."
echo

echo "3. TOO MANY SHARDS"
echo "   ----------------------------------------------------------"
echo "   Every shard has overhead."
echo "   Thousands of small shards can consume substantial heap."
echo "   Consolidating indices/shards can dramatically improve this."
echo

echo "4. FIELDDATA"
echo "   ----------------------------------------------------------"
echo "   Large fielddata is a classic cause of heap consumption."
echo "   Aggregating/sorting on text fields can be especially problematic."
echo "   Prefer keyword/numeric/date fields for aggregations and sorting."
echo

echo "5. MIDNIGHT INDEX ROTATION / ILM"
echo "   ----------------------------------------------------------"
echo "   If memory drops sharply at exactly 00:00, investigate ILM,"
echo "   rollover, index deletion, force merge, snapshot or scheduled"
echo "   maintenance jobs."
echo
echo "   Check:"
echo "     curl -s '$ES_URL/_ilm/status?pretty'"
echo "     curl -s '$ES_URL/_cat/aliases?v'"
echo "     curl -s '$ES_URL/_cat/indices?v'"
echo

echo "6. ACTUAL MEMORY LEAK"
echo "   ----------------------------------------------------------"
echo "   A genuine leak is possible, but the clean midnight reset makes"
echo "   index lifecycle, caches and Linux page cache more suspicious."
echo

echo "============================================================"
echo " END OF DIAGNOSTIC"
echo "============================================================"
echo

echo "TIP:"
echo "Run this once when memory is HIGH and again shortly after 00:00."
echo "Comparing the two outputs will be much more informative than a"
echo "single snapshot."
echo
