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
else
    DRIVERS=$(ls src/ls_*.c | sed 's/src\/ls_//;s/\.c//')
fi

# Function to wait for DB
wait_for_db() {
    local host=$1
    local port=$2
    echo -n "Waiting for $host:$port... "
    for i in {1..30}; do
        if timeout 1s bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null; then
            echo -e "${GREEN}Ready!${NC}"
            return 0
        fi
        sleep 1
    done
    echo -e "${RED}Timeout!${NC}"
    return 1
}

echo -e "${GREEN}Compiling with AddressSanitizer (ASAN)...${NC}"

# Setup Lua environment
mkdir -p src/luasql

# Compilation setup for container environment
export LUA_SYS_VER="5.4"
export DRIVER_INCS_mysql="-I/usr/include/mysql"
export DRIVER_LIBS_mysql="-L/usr/lib/x86_64-linux-gnu -lmariadb -lz"
export DRIVER_INCS_postgres="-I/usr/include/postgresql"
export DRIVER_LIBS_postgres="-L/usr/lib -lpq"
export DRIVER_INCS_sqlite="-I/usr/local/include"
export DRIVER_LIBS_sqlite="-L/usr/local/lib -lsqlite"
export DRIVER_INCS_sqlite3="-I/usr/include"
export DRIVER_LIBS_sqlite3="-lsqlite3"
export DRIVER_INCS_firebird="-I/usr/include/firebird"
export DRIVER_LIBS_firebird="-lfbclient"
export DRIVER_INCS_oci8="-I/opt/oracle/instantclient_21_13/sdk/include"
export DRIVER_LIBS_oci8="-L/opt/oracle/instantclient_21_13 -lclntsh"
export DRIVER_INCS_duckdb="-I/usr/local/include"
export DRIVER_LIBS_duckdb="-L/usr/local/lib -lduckdb"

# Statistics
TOTAL_TESTS=0
TOTAL_PASSED=0
TOTAL_FAILED=0
TESTED_DRIVERS=()

for d in ${DRIVERS[@]}; do
    [ -z "$d" ] && continue
    
    echo -e "\n${BLUE}>>> Processing driver ${BOLD}[$d]${NC}${BLUE} with ASAN${NC}"

    # 1. Build driver
    make clean > /dev/null
    ASAN_FLAGS="-fsanitize=address -fno-omit-frame-pointer -g -O1"
    export CFLAGS="$ASAN_FLAGS"
    export LDFLAGS="-fsanitize=address"

    echo -e "Building ${BOLD}$d${NC} with ASAN..."
    if ! make "$d" OPTFLAGS="$ASAN_FLAGS"; then
        echo -e "${RED}Failed to build $d. Skipping...${NC}"
        continue
    fi

    # 2. Setup subfolder
    mkdir -p src/luasql
    if [ -f "src/$d.so" ]; then
        mv "src/$d.so" "src/luasql/$d.so"
    fi

    # 3. Setup environment and wait for DB
    DB_DS="luasql_test"
    DB_UN="luasql"
    DB_PW="luasql"
    DB_HO=""

    case "$d" in
        duckdb)  DB_DS="test_asan.db" ;;
        sqlite3) DB_DS="test_asan.db" ;;
        sqlite)  DB_DS="test_asan.db" ;;
        postgres) 
            DB_HO="$DB_HOST_POSTGRES"
            wait_for_db "$DB_HO" 5432 || continue
            ;;
        mysql)    
            DB_HO="$DB_HOST_MYSQL"
            wait_for_db "$DB_HO" 3306 || continue
            ;;
        firebird) 
            DB_HO="$DB_HOST_FIREBIRD"
            wait_for_db "$DB_HO" 3050 || continue
            DB_DS="$DB_HO:luasql_test.fdb" 
            ;;
        oci8)
            DB_HO="${DB_HOST_ORACLE:-db-oracle}"
            wait_for_db "$DB_HO" 1521 || continue
            DB_DS="//$DB_HO:1521/FREEPDB1"
            ;;
        odbc)
            wait_for_db "$DB_HOST_POSTGRES" 5432 || continue
            DRIVER_PATH=$(find /usr/lib -name "psqlodbcw.so" | head -n 1)
            if [ -n "$DRIVER_PATH" ]; then
                echo "Configuring ODBC..."
                cat <<EOF > /etc/odbcinst.ini
[PostgreSQL]
Driver = $DRIVER_PATH
EOF
                cat <<EOF > /etc/odbc.ini
[luasql_test]
Driver = PostgreSQL
Servername = ${DB_HOST_POSTGRES:-db-postgres}
Port = 5432
Database = $DB_NAME
EOF
            fi
            ;;
    esac

    # 4. Run the test
    ((TOTAL_TESTS++))
    TESTED_DRIVERS+=("$d")
    export LUA_CPATH="$PROJECT_ROOT/src/?.so;;"
    export LUA_PATH="$PROJECT_ROOT/tests/?.lua;;"
    
    # Detect ASAN library path for LD_PRELOAD
    ASAN_LIB=$(gcc -print-file-name=libasan.so)
    if [[ ! "$ASAN_LIB" =~ ^/ ]]; then
        ASAN_LIB=$(find /usr/lib/x86_64-linux-gnu /usr/lib -name "libasan.so.[0-9]*" 2>/dev/null | sort -V | tail -n 1)
    fi
    
    if [ -f "$ASAN_LIB" ]; then
        export LD_PRELOAD="$ASAN_LIB"
    fi

    # ASAN configuration
    CURRENT_ASAN_OPTIONS="abort_on_error=1:symbolize=1"
    if [[ "$d" == "duckdb" || "$d" == "firebird" ]]; then
        CURRENT_ASAN_OPTIONS="intercept_exceptions=0:verify_asan_link_order=0:$CURRENT_ASAN_OPTIONS"
    fi
    export ASAN_OPTIONS="$CURRENT_ASAN_OPTIONS"
    export LSAN_OPTIONS="suppressions=$PROJECT_ROOT/scripts/asan.supp:print_suppressions=0"

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

    if [ $TEST_RET -eq 0 ]; then
        echo -e "${GREEN}✔ ASAN: No errors detected for $d!${NC}"
        ((TOTAL_PASSED++))
        touch "$LOG_DIR/asan_$d.ok"
    else
        echo -e "${RED}✘ ASAN: Memory errors or failure for $d!${NC}"
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

for d in ${DRIVERS[@]}; do
    STATUS="SKIP"
    ERRORS="N/A"
    if [ -f "$LOG_DIR/asan_$d.ok" ]; then
        STATUS="PASS"
        ERRORS="NONE"
    else
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
    printf "%-20s | ${COLOR}%-12s${NC} | ${COLOR}%-12s${NC}\n" "$d" "$STATUS" "$ERRORS"
done

echo "----------------------------------------------------------------"
[ $TOTAL_FAILED -ne 0 ] && exit 1 || exit 0
