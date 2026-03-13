#!/bin/bash

# Ensure we are in the project root
cd "$(dirname "$0")/.."
PROJECT_ROOT=$(pwd)

# Output colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

LOG_DIR="$PROJECT_ROOT/valgrind_logs"
mkdir -p "$LOG_DIR"

# Target driver from argument
TARGET_DRIVER=$1

# Detect drivers
if [ -n "$TARGET_DRIVER" ]; then
    if [ ! -f "src/ls_$TARGET_DRIVER.c" ]; then
        echo -e "${RED}Driver '$TARGET_DRIVER' not found in src/ls_$TARGET_DRIVER.c${NC}"
        exit 1
    fi
    DRIVERS=("$TARGET_DRIVER")
    rm -f "$LOG_DIR/valgrind_$TARGET_DRIVER.log"*
else
    DRIVERS=$(ls src/ls_*.c | sed 's/src\/ls_//;s/\.c//')
    rm -f "$LOG_DIR"/*
fi

echo -e "${GREEN}Preparing LuaSQL drivers with debug symbols...${NC}"

# Setup Lua environment
mkdir -p src/luasql

# Statistics
TOTAL_TESTS=0
TOTAL_PASSED=0
TOTAL_FAILED=0
TESTED_DRIVERS=()

for d in ${DRIVERS[@]}; do
    [ -z "$d" ] && continue
    
    echo -e "\n${BLUE}>>> Processing driver ${BOLD}[$d]${NC}${BLUE} with Valgrind${NC}"

    # 1. Clean and Apply temporary patch if exists
    make clean > /dev/null
    PATCH="patches/${d}_memory_fix.patch"
    PATCH_APPLIED=0
    if [ "$SKIP_PATCHING" != "1" ] && [ -f "$PATCH" ]; then
        echo -e "${YELLOW}Applying temporary patch $PATCH...${NC}"
        if patch -p0 < "$PATCH" > /dev/null; then
            PATCH_APPLIED=1
        else
            echo -e "${RED}Failed to apply patch $PATCH${NC}"
        fi
    fi

    # 2. Build driver
    echo -e "Building ${BOLD}$d${NC}..."
    if ! make "$d" OPTFLAGS="-g -O0"; then
        echo -e "${RED}Failed to build $d. Skipping...${NC}"
        [ $PATCH_APPLIED -eq 1 ] && patch -R -p0 < "$PATCH" > /dev/null
        continue
    fi

    # 3. Setup symlink
    if [ -f "src/$d.so" ]; then
        ln -sf "../$d.so" "src/luasql/$d.so"
    fi

    # 4. Run Valgrind
    ((TOTAL_TESTS++))
    TESTED_DRIVERS+=("$d")
    LOG="$LOG_DIR/valgrind_$d.log"
    
    # Default connection params
    DB_DS="luasql_test"
    DB_UN="luasql"
    DB_PW="luasql"
    DB_HO=""

    case "$d" in
        duckdb)  DB_DS="test_duckdb_valgrind.db"; T_LIMIT="300s"; V_FLAGS="$V_FLAGS --max-stackframe=16777216"; export RUNNING_UNDER_VALGRIND=1 ;;
        sqlite3) DB_DS="test_valgrind.db"; unset RUNNING_UNDER_VALGRIND ;;
        sqlite)  DB_DS="test_valgrind_v2.db"; unset RUNNING_UNDER_VALGRIND ;;
        postgres) DB_HO="$DB_HOST_POSTGRES"; unset RUNNING_UNDER_VALGRIND ;;
        mysql)    DB_HO="$DB_HOST_MYSQL"; unset RUNNING_UNDER_VALGRIND ;;
        firebird) DB_DS="$DB_HOST_FIREBIRD:luasql_test.fdb"; unset RUNNING_UNDER_VALGRIND ;;
        *) unset RUNNING_UNDER_VALGRIND ;;
    esac
    
    # Environment variables for Lua
    export LUA_CPATH="$PROJECT_ROOT/src/?.so;;"
    export LUA_PATH="$PROJECT_ROOT/tests/?.lua;;"

    echo -e "Running Valgrind for $d..."
    (
        set +m
        cd tests
        [ -f "$DB_DS" ] && [[ "$d" == "sqlite"* || "$d" == "duckdb" ]] && rm -f "$DB_DS"
        timeout --kill-after=10s "$T_LIMIT" valgrind $V_FLAGS \
                 --log-file="$LOG" --error-exitcode=1 lua test.lua "$d" "$DB_DS" "$DB_UN" "$DB_PW" "$DB_HO"
        RET=$?
        [ -f "$DB_DS" ] && [[ "$d" == "sqlite"* || "$d" == "duckdb" ]] && rm -f "$DB_DS"
        exit $RET
    ) 2>/dev/null
    
    EXIT_CODE=$?
    
    if [ $EXIT_CODE -eq 0 ]; then
        echo -e "${GREEN}OK${NC}"
        ((TOTAL_PASSED++))
        rm -f "$LOG"
    elif [ $EXIT_CODE -eq 124 ] || [ $EXIT_CODE -eq 137 ]; then
        echo -e "${YELLOW}TIMEOUT${NC}"
        ((TOTAL_FAILED++))
        echo "TIMEOUT - Process killed after $T_LIMIT" > "$LOG.status"
    else
        echo -e "${RED}LEAK/ERROR${NC}"
        ((TOTAL_FAILED++))
    fi

    # 5. Revert driver patch
    if [ $PATCH_APPLIED -eq 1 ]; then
        echo -e "${YELLOW}Reverting temporary patch $PATCH...${NC}"
        patch -R -p0 < "$PATCH" > /dev/null
    fi
done

# --- Final Statistics Report ---
echo -e "\n${YELLOW}${BOLD}================================================================${NC}"
echo -e "${YELLOW}${BOLD}                 VALGRIND MEMORY LEAK REPORT                    ${NC}"
echo -e "${YELLOW}${BOLD}================================================================${NC}"
printf "%-20s | %-12s | %-12s | %s\n" "Driver" "Status" "Leaks" "Log File"
echo "----------------------------------------------------------------"

if [ -n "$TARGET_DRIVER" ]; then
    SHOW_DRIVERS=("$TARGET_DRIVER")
else
    SHOW_DRIVERS=$(ls src/ls_*.c | sed 's/src\/ls_//;s/\.c//')
fi

for d in ${SHOW_DRIVERS[@]}; do
    STATUS="SKIP"
    LEAK="N/A"
    LOG_FILE="-"
    
    if [ -f "$LOG_DIR/valgrind_$d.log.status" ]; then
        STATUS="TIMEOUT"
        LEAK="???"
        LOG_FILE="timed out (driver too heavy)"
    elif [ -f "$LOG_DIR/valgrind_$d.log" ]; then
        STATUS="FAIL"
        LEAK="YES"
        LOG_FILE="$LOG_DIR/valgrind_$d.log"
    else
        MATCH=0
        for td in ${TESTED_DRIVERS[@]}; do [[ "$td" == "$d" ]] && MATCH=1 && break; done
        if [ $MATCH -eq 1 ]; then
            STATUS="PASS"
            LEAK="NO"
        fi
    fi
    
    COLOR=$NC
    [ "$STATUS" == "FAIL" ] && COLOR=$RED
    [ "$STATUS" == "PASS" ] && COLOR=$GREEN
    [ "$STATUS" == "TIMEOUT" ] && COLOR=$YELLOW
    
    printf "%-20s | " "$d"
    printf "${COLOR}%-12s${NC} | " "$STATUS"
    printf "${COLOR}%-12s${NC} | " "$LEAK"
    printf "%s\n" "$LOG_FILE"
done

echo "----------------------------------------------------------------"
if [ -z "$TARGET_DRIVER" ]; then
    printf "${BOLD}%-20s | %-12d | %-12d | %d${NC}\n" "OVERALL" "$TOTAL_TESTS" "$TOTAL_PASSED" "$TOTAL_FAILED"
    echo -e "${YELLOW}${BOLD}================================================================${NC}"
fi

[ $TOTAL_FAILED -ne 0 ] && exit 1 || exit 0
