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

echo -e "${GREEN}Preparing LuaSQL drivers with debug symbols...${NC}"

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
    
    echo -e "\n${BLUE}>>> Processing driver ${BOLD}[$d]${NC}${BLUE} with Valgrind${NC}"

    # 1. Build driver
    make clean > /dev/null
    echo -e "Building ${BOLD}$d${NC}..."
    if ! make "$d" OPTFLAGS="-g -O0"; then
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
        duckdb)  DB_DS="test_valgrind.db" ;;
        sqlite3) DB_DS="test_valgrind.db" ;;
        sqlite)  DB_DS="test_valgrind.db" ;;
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

    # 4. Run Valgrind
    ((TOTAL_TESTS++))
    TESTED_DRIVERS+=("$d")
    LOG="$LOG_DIR/valgrind_$d.log"
    V_FLAGS="--leak-check=full --show-leak-kinds=definite --errors-for-leak-kinds=definite --track-origins=yes --suppressions=$PROJECT_ROOT/scripts/valgrind.supp"
    [ "$d" == "duckdb" ] && V_FLAGS="$V_FLAGS --max-stackframe=16777216"
    
    # Environment variables for Lua
    export LUA_CPATH="$PROJECT_ROOT/src/?.so;;"
    export LUA_PATH="$PROJECT_ROOT/tests/?.lua;;"

    echo -e "Running Valgrind for $d..."
    (
        set +m
        cd tests
        [ -f "$DB_DS" ] && [[ "$d" == "sqlite"* || "$d" == "duckdb" ]] && rm -f "$DB_DS"
        valgrind $V_FLAGS --log-file="$LOG" --error-exitcode=1 lua test.lua "$d" "$DB_DS" "$DB_UN" "$DB_PW" "$DB_HO"
        RET=$?
        [ -f "$DB_DS" ] && [[ "$d" == "sqlite"* || "$d" == "duckdb" ]] && rm -f "$DB_DS"
        exit $RET
    ) 2>/dev/null
    
    EXIT_CODE=$?
    
    if [ $EXIT_CODE -eq 0 ]; then
        echo -e "${GREEN}OK${NC}"
        ((TOTAL_PASSED++))
        rm -f "$LOG"
    else
        echo -e "${RED}LEAK/ERROR (see $LOG)${NC}"
        ((TOTAL_FAILED++))
    fi
done

# --- Final Statistics Report ---
echo -e "\n${YELLOW}${BOLD}================================================================${NC}"
echo -e "${YELLOW}${BOLD}                 VALGRIND MEMORY LEAK REPORT                    ${NC}"
echo -e "${YELLOW}${BOLD}================================================================${NC}"
printf "%-20s | %-12s | %-12s | %s\n" "Driver" "Status" "Leaks" "Log File"
echo "----------------------------------------------------------------"

for d in ${DRIVERS[@]}; do
    STATUS="SKIP"
    LEAK="N/A"
    LOG_FILE="-"
    
    if [ -f "$LOG_DIR/valgrind_$d.log" ]; then
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
    
    printf "%-20s | " "$d"
    printf "${COLOR}%-12s${NC} | " "$STATUS"
    printf "${COLOR}%-12s${NC} | " "$LEAK"
    printf "%s\n" "$LOG_FILE"
done

echo "----------------------------------------------------------------"
[ $TOTAL_FAILED -ne 0 ] && exit 1 || exit 0
