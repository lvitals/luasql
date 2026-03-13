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

LOG_DIR="$PROJECT_ROOT/valgrind_logs" # We can reuse logs folder for status
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
else
    DRIVERS=$(ls src/ls_*.c | sed 's/src\/ls_//;s/\.c//')
fi

echo -e "${GREEN}Compiling with AddressSanitizer (ASAN)...${NC}"

# Setup Lua environment
mkdir -p src/luasql

# Statistics
TOTAL_TESTS=0
TOTAL_PASSED=0
TOTAL_FAILED=0
TESTED_DRIVERS=()

for d in ${DRIVERS[@]}; do
    [ -z "$d" ] && continue
    
    echo -e "\n${BLUE}>>> Processing driver ${BOLD}[$d]${NC}${BLUE} with ASAN${NC}"

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

    # 2. Compile with ASAN flags
    ASAN_FLAGS="-fsanitize=address -fno-omit-frame-pointer -g -O1"
    export CFLAGS="$ASAN_FLAGS"
    export LDFLAGS="-fsanitize=address"

    echo -e "Building ${BOLD}$d${NC} with ASAN..."
    if ! make "$d" OPTFLAGS="$ASAN_FLAGS"; then
        echo -e "${RED}Failed to build $d. Skipping...${NC}"
        [ $PATCH_APPLIED -eq 1 ] && patch -R -p0 < "$PATCH" > /dev/null
        continue
    fi

    # 3. Setup symlink
    if [ -f "src/$d.so" ]; then
        ln -sf "../$d.so" "src/luasql/$d.so"
    fi

    # 4. Run the test
    ((TOTAL_TESTS++))
    TESTED_DRIVERS+=("$d")
    export LUA_CPATH="$PROJECT_ROOT/src/?.so;;"
    export LUA_PATH="$PROJECT_ROOT/tests/?.lua;;"
    
    # Detect ASAN library path for LD_PRELOAD
    ASAN_LIB=$(gcc -print-file-name=libasan.so)
    if [[ ! "$ASAN_LIB" =~ ^/ ]]; then
        # If not an absolute path, try common locations
        ASAN_LIB=$(find /usr/lib/x86_64-linux-gnu /usr/lib -name "libasan.so.[0-9]*" 2>/dev/null | sort -V | tail -n 1)
    fi
    
    if [ -f "$ASAN_LIB" ]; then
        export LD_PRELOAD="$ASAN_LIB"
        echo -e "Using ASAN_LIB: ${BLUE}$ASAN_LIB${NC}"
    else
        echo -e "${YELLOW}Warning: libasan not found for LD_PRELOAD. This might cause issues with C++ exceptions.${NC}"
    fi

    # Reset ASAN_OPTIONS for each driver to avoid accumulation
    CURRENT_ASAN_OPTIONS="abort_on_error=1:symbolize=1"
    if [[ "$d" == "duckdb" || "$d" == "firebird" ]]; then
        # C++ exception heavy drivers often crash in ASAN interceptors
        # Using intercept_exceptions=0 and verify_asan_link_order=0
        CURRENT_ASAN_OPTIONS="intercept_exceptions=0:verify_asan_link_order=0:$CURRENT_ASAN_OPTIONS"
    else
        CURRENT_ASAN_OPTIONS="intercept_exceptions=1:$CURRENT_ASAN_OPTIONS"
    fi
    export ASAN_OPTIONS="$CURRENT_ASAN_OPTIONS"
    export LSAN_OPTIONS="suppressions=$PROJECT_ROOT/patches/asan.supp:print_suppressions=0"

    # Default connection params
    DB_DS="luasql_test"
    DB_UN="luasql"
    DB_PW="luasql"
    DB_HO=""

    case "$d" in
        duckdb)  DB_DS="test_duckdb_asan.db" ;;
        sqlite3) DB_DS="test_asan.db" ;;
        sqlite)  DB_DS="test_asan_v2.db" ;;
        postgres) DB_HO="$DB_HOST_POSTGRES"; DB_DS="luasql_test" ;;
        mysql)    DB_HO="$DB_HOST_MYSQL"; DB_DS="luasql_test" ;;
        firebird) DB_DS="$DB_HOST_FIREBIRD:luasql_test.fdb" ;;
        *) ;;
    esac

    echo -e "Running tests for $d under ASAN..."
    (
        cd tests
        [ -f "$DB_DS" ] && [[ "$d" == "sqlite"* || "$d" == "duckdb" ]] && rm -f "$DB_DS"
        lua test.lua "$d" "$DB_DS" "$DB_UN" "$DB_PW" "$DB_HO"
        RET=$?
        [ -f "$DB_DS" ] && [[ "$d" == "sqlite"* || "$d" == "duckdb" ]] && rm -f "$DB_DS"
        exit $RET
    )
    TEST_RET=$?
    
    unset LD_PRELOAD

    # 5. Revert patch
    if [ $PATCH_APPLIED -eq 1 ]; then
        echo -e "${YELLOW}Reverting temporary patch $PATCH...${NC}"
        patch -R -p0 < "$PATCH" > /dev/null
    fi

    if [ $TEST_RET -eq 0 ]; then
        echo -e "${GREEN}✔ ASAN: No immediate memory errors detected for $d!${NC}"
        ((TOTAL_PASSED++))
        touch "$LOG_DIR/asan_$d.ok"
    else
        echo -e "${RED}✘ ASAN: Memory errors or test failure for $d!${NC}"
        ((TOTAL_FAILED++))
        rm -f "$LOG_DIR/asan_$d.ok"
    fi
done

# --- Final Statistics Report ---
echo -e "\n${YELLOW}${BOLD}================================================================${NC}"
echo -e "${YELLOW}${BOLD}                 ASAN MEMORY ANALYSIS REPORT                    ${NC}"
echo -e "${YELLOW}${BOLD}================================================================${NC}"
printf "%-20s | %-12s | %-12s\n" "Driver" "Status" "ASAN Errors"
echo "----------------------------------------------------------------"

if [ -n "$TARGET_DRIVER" ]; then
    SHOW_DRIVERS=("$TARGET_DRIVER")
else
    SHOW_DRIVERS=$(ls src/ls_*.c | sed 's/src\/ls_//;s/\.c//')
fi

for d in ${SHOW_DRIVERS[@]}; do
    STATUS="SKIP"
    ERRORS="N/A"
    
    if [ -f "$LOG_DIR/asan_$d.ok" ]; then
        STATUS="PASS"
        ERRORS="NONE"
    else
        # Check if it was actually tested
        MATCH=0
        for td in ${TESTED_DRIVERS[@]}; do [[ "$td" == "$d" ]] && MATCH=1 && break; done
        if [ $MATCH -eq 1 ]; then
            STATUS="FAIL"
            ERRORS="YES"
        fi
    fi
    
    COLOR=$NC
    [ "$STATUS" == "FAIL" ] && COLOR=$RED
    [ "$STATUS" == "PASS" ] && COLOR=$GREEN
    
    printf "%-20s | " "$d"
    printf "${COLOR}%-12s${NC} | " "$STATUS"
    printf "${COLOR}%-12s${NC}\n" "$ERRORS"
done

echo "----------------------------------------------------------------"
if [ -z "$TARGET_DRIVER" ]; then
    printf "${BOLD}%-20s | %-12d | %-12d${NC}\n" "OVERALL" "$TOTAL_TESTS" "$TOTAL_FAILED"
    echo -e "${YELLOW}${BOLD}================================================================${NC}"
fi

[ $TOTAL_FAILED -ne 0 ] && exit 1 || exit 0
