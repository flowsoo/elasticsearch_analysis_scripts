#!/usr/bin/env bash

echo "============================================================"
echo " Linux Memory Diagnostic"
echo " $(date)"
echo " Host: $(hostname)"
echo "============================================================"

echo
echo "### 1. FREE -H"
echo "------------------------------------------------------------"
free -h

echo
echo "### 2. TOP MEMORY PROCESSES"
echo "------------------------------------------------------------"
ps aux --sort=-%mem | head -15

echo
echo "### 3. /PROC/MEMINFO"
echo "------------------------------------------------------------"
grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapCached|Active|Inactive|Active\(file\)|Inactive\(file\)|Active\(anon\)|Inactive\(anon\)|Unevictable|SReclaimable|Shmem|SwapTotal|SwapFree):' /proc/meminfo

echo
echo "### 4. VMSTAT"
echo "------------------------------------------------------------"
vmstat 1 5

echo
echo "### 5. SWAP"
echo "------------------------------------------------------------"
swapon --show

echo
echo "### 6. DISK / FILESYSTEM"
echo "------------------------------------------------------------"
df -hT

echo
echo "### 7. KIBANA / ELASTICSEARCH PROCESSES"
echo "------------------------------------------------------------"
ps -eo pid,ppid,user,%mem,%cpu,rss,vsz,etime,cmd --sort=-%mem \
    | grep -Ei 'kibana|elasticsearch|node' \
    | grep -v grep

echo
echo "### 8. MEMORY SUMMARY"
echo "------------------------------------------------------------"

awk '
/^MemTotal:/     { total=$2 }
/^MemFree:/      { free=$2 }
/^MemAvailable:/ { avail=$2 }
/^Buffers:/      { buffers=$2 }
/^Cached:/       { cached=$2 }
/^SReclaimable:/ { reclaim=$2 }
/^SwapTotal:/    { swap_total=$2 }
/^SwapFree:/     { swap_free=$2 }

END {
    printf "MemTotal:     %.2f GB\n", total/1024/1024
    printf "MemFree:      %.2f GB\n", free/1024/1024
    printf "MemAvailable: %.2f GB\n", avail/1024/1024
    printf "Buffers:      %.2f GB\n", buffers/1024/1024
    printf "Cached:       %.2f GB\n", cached/1024/1024
    printf "Reclaimable:  %.2f GB\n", reclaim/1024/1024

    if (swap_total > 0)
        printf "SwapUsed:     %.2f GB\n", (swap_total-swap_free)/1024/1024
    else
        printf "SwapUsed:     0 GB\n"
}' /proc/meminfo

echo
echo "============================================================"
echo " End of diagnostic"
echo "============================================================"
