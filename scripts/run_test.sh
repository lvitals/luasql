#!/bin/bash
# ==============================================================================
# LuaSQL Single Driver Test Runner
# ------------------------------------------------------------------------------
# This script runs tests for a specific database driver.
# It supports three modes: functional test, Valgrind (leaks), and ASAN.
#
# Usage: ./scripts/run_test.sh <driver> [mode]
# Examples:
#   ./scripts/run_test.sh mysql
#   ./scripts/run_test.sh postgres valgrind
#   ./scripts/run_test.sh sqlite3 asan
# ==============================================================================

# Ensure we are in the project root
cd "$(dirname "$0")/.."
PROJECT_ROOT=$(pwd)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

DRIVER=$1
MODE=${2:-test} # Default mode is functional test

if [ -z "$DRIVER" ]; then
    echo -e "${RED}Error: No driver specified.${NC}"
    echo -e "Usage: $0 <driver> [test|valgrind|asan]"
    exit 1
fi

# Validate driver source existence
if [ ! -f "src/ls_$DRIVER.c" ]; then
    echo -e "${RED}Error: Driver source 'src/ls_$DRIVER.c' not found.${NC}"
    exit 1
fi

echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}Testing driver: ${BOLD}[$DRIVER]${NC}${BLUE} in mode: ${BOLD}[$MODE]${NC}"
echo -e "${BLUE}================================================================${NC}"

# Connection parameters from env or defaults
if [ "$RUNNING_IN_DOCKER" == "1" ]; then
    export LUA_SYS_VER="5.4"
    export LUA_INC="/usr/include/lua5.4"
    export LUA_INC_DIR="/usr/include/lua5.4"
    DB_NAME=${DB_NAME:-luasql_test}
    DB_USER=${DB_USER:-luasql}
    DB_PASS=${DB_PASS:-luasql}
fi

# Function to wait for DB availability
wait_for_db() {
    local host=$1
    local port=$2
    if [ -z "$host" ]; then return; fi
    echo -n "Waiting for $host:$port... "
    for i in {1..30}; do
        if timeout 1s bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null; then
            echo -e "${GREEN}Ready!${NC}"
            return 0
        fi
        sleep 1
    done
    echo -e "${RED}Timeout waiting for $host:$port${NC}"
    return 1
}

APPLIED_PATCHES=()
cleanup() {
    local exit_code=$?
    echo -e "\n${YELLOW}>>> Cleaning up...${NC}"
    
    # Ensure we are in the project root for relative paths to work
    cd "$PROJECT_ROOT"

    # Revert patches in reverse order
    if [ ${#APPLIED_PATCHES[@]} -gt 0 ]; then
        echo -e "${YELLOW}Reverting applied patches...${NC}"
        for (( i=${#APPLIED_PATCHES[@]}-1; i>=0; i-- )); do
            p=${APPLIED_PATCHES[$i]}
            echo -n "Reverting $p... "
            if patch -R -p0 < "$p" > /dev/null 2>&1; then
                echo -e "${GREEN}OK${NC}"
            else
                echo -e "${RED}FAILED${NC}"
            fi
        done
    fi

    # Cleanup temp files
    cd "$PROJECT_ROOT"
    [ -f "tests/$DB_DS" ] && [[ "$DRIVER" == "sqlite"* || "$DRIVER" == "duckdb" ]] && rm -f "tests/$DB_DS"

    echo -e "\n${BLUE}----------------------------------------------------------------${NC}"
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}${BOLD}RESULT: PASSED${NC}"
    else
        echo -e "${RED}${BOLD}RESULT: FAILED${NC}"
    fi
    echo -e "${BLUE}================================================================${NC}"
    exit $exit_code
}

# Set trap for automatic cleanup on exit (including errors and signals)
trap cleanup EXIT

# 1. Apply necessary patches
echo -e "\n${YELLOW}>>> Applying infrastructure patches...${NC}"
ORDERED_PATCHES=(
    "patches/tests_common_connection_args.patch"
)

# Driver-specific patches
case "$DRIVER" in
    firebird) ORDERED_PATCHES+=("patches/tests_firebird_connection_args.patch") ;;
    *) ;;
esac

# Common memory fix patch for the driver itself
ORDERED_PATCHES+=("patches/${DRIVER}_memory_fix.patch")

for p in "${ORDERED_PATCHES[@]}"; do
    if [ -f "$p" ]; then
        echo -n "Applying $p... "
        if patch -p0 --ignore-whitespace < "$p" > /dev/null 2>&1; then
            echo -e "${GREEN}OK${NC}"
            APPLIED_PATCHES+=("$p")
        else
            echo -e "${YELLOW}SKIPPED (already applied or not applicable)${NC}"
        fi
    fi
done

# 2. Determine connection arguments based on driver
DB_DS="$DB_NAME"
DB_UN="$DB_USER"
DB_PW="$DB_PASS"
DB_HO=""
DB_PO=""

case "$DRIVER" in
    duckdb)   DB_DS="test_single_$MODE.db" ;;
    sqlite3)  DB_DS="test_single_$MODE.db" ;;
    sqlite)   DB_DS="test_single_$MODE.db" ;;
    postgres) DB_HO="$DB_HOST_POSTGRES" ;;
    mysql)    DB_HO="$DB_HOST_MYSQL" ;;
    firebird) DB_DS="$DB_HOST_FIREBIRD:luasql_test.fdb" ;;
    oci8)     DB_DS="//${DB_HOST_ORACLE:-db-oracle}:1521/FREEPDB1" ;;
    *) ;;
esac

# 3. Wait for database if running in Docker
if [ "$RUNNING_IN_DOCKER" == "1" ]; then
    case "$DRIVER" in
        postgres) wait_for_db "$DB_HOST_POSTGRES" 5432 || exit 1 ;;
        odbc)     wait_for_db "$DB_HOST_POSTGRES" 5432 || exit 1 ;;
        mysql)    wait_for_db "$DB_HOST_MYSQL" 3306 || exit 1 ;;
        firebird) wait_for_db "$DB_HOST_FIREBIRD" 3050 || exit 1 ;;
        oci8)     
            wait_for_db "$DB_HOST_ORACLE" 1521 || exit 1
            echo -e "${YELLOW}Waiting for Oracle service FREEPDB1 to be ready (this can take up to 10 minutes)...${NC}"
            for i in {1..60}; do
                ERR_MSG=$(echo "exit" | sqlplus -L system/luasql@${DB_HOST_ORACLE}/FREEPDB1 2>&1)
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}Ready!${NC}"
                    break
                fi
                [ $((i % 5)) -eq 0 ] && echo "Still waiting for FREEPDB1 ($((i * 10))s)... Last error: $(echo $ERR_MSG | head -n 1)"
                if [ $i -eq 60 ]; then
                    echo -e "${RED}Timeout!${NC}"
                    exit 1
                fi
                sleep 10
            done
            export NLS_LANG="AMERICAN_AMERICA.AL32UTF8"
            ;;
        *) ;;
    esac
fi

# 3.5. Configure ODBC if needed
if [ "$DRIVER" == "odbc" ]; then
    # Locate the PostgreSQL ODBC driver library
    DRIVER_PATH=$(find /usr/lib -name "psqlodbcw.so" | head -n 1)
    if [ -n "$DRIVER_PATH" ]; then
        echo -e "${YELLOW}Configuring ODBC with driver: $DRIVER_PATH${NC}"
        cat <<EOF > /etc/odbcinst.ini
[PostgreSQL]
Description = PostgreSQL ODBC driver (Unicode)
Driver      = $DRIVER_PATH
EOF
        cat <<EOF > /etc/odbc.ini
[luasql_test]
Driver              = PostgreSQL
Servername          = ${DB_HOST_POSTGRES:-db-postgres}
Port                = 5432
Database            = $DB_NAME
ByteaAsLongVarBinary = 1
MaxVarcharSize      = 255
MaxLongVarcharSize  = 8190
EOF
    else
        echo -e "${RED}Error: PostgreSQL ODBC driver (psqlodbcw.so) not found.${NC}"
        exit 1
    fi
fi

# 4. Compilation setup
export LUA_CPATH="$PROJECT_ROOT/src/?.so;;"
export LUA_PATH="$PROJECT_ROOT/tests/?.lua;;"

# Driver-specific compilation flags for the Makefile
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

# Build the driver if needed
echo -e "${YELLOW}Building driver $DRIVER...${NC}"
make clean > /dev/null

COMPILE_FLAGS="-g -O1"
if [ "$MODE" == "asan" ]; then
    COMPILE_FLAGS="-fsanitize=address -fno-omit-frame-pointer -g -O1"
    export LDFLAGS="-fsanitize=address"
elif [ "$MODE" == "valgrind" ]; then
    COMPILE_FLAGS="-g -O0"
fi

if ! make "$DRIVER" OPTFLAGS="$COMPILE_FLAGS" > /tmp/build_single.log 2>&1; then
    echo -e "${RED}Build failed! See /tmp/build_single.log${NC}"
    exit 1
fi
echo -e "${GREEN}Build successful.${NC}"

# Setup symlink for Lua require
mkdir -p src/luasql
ln -sf "../$DRIVER.so" "src/luasql/$DRIVER.so"

# Execution
cd tests
[ -f "$DB_DS" ] && [[ "$DRIVER" == "sqlite"* || "$DRIVER" == "duckdb" ]] && rm -f "$DB_DS"

case "$MODE" in
    test)
        echo -e "${YELLOW}Running functional test...${NC}"
        lua test.lua "$DRIVER" "$DB_DS" "$DB_UN" "$DB_PW" "$DB_HO" "$DB_PO"
        RET=$?
        ;;

    valgrind)
        echo -e "${YELLOW}Running Valgrind leak detection...${NC}"
        V_FLAGS="--leak-check=full --show-leak-kinds=definite --errors-for-leak-kinds=definite --track-origins=yes --suppressions=$PROJECT_ROOT/patches/valgrind.supp"
        [ "$DRIVER" == "duckdb" ] && V_FLAGS="$V_FLAGS --max-stackframe=16777216"
        valgrind $V_FLAGS lua test.lua "$DRIVER" "$DB_DS" "$DB_UN" "$DB_PW" "$DB_HO" "$DB_PO"
        RET=$?
        ;;
    asan)
        echo -e "${YELLOW}Running ASAN memory analysis...${NC}"
        # Detect ASAN library for LD_PRELOAD
        ASAN_LIB=$(gcc -print-file-name=libasan.so)
        if [[ ! "$ASAN_LIB" =~ ^/ ]]; then
            ASAN_LIB=$(find /usr/lib/x86_64-linux-gnu /usr/lib -name "libasan.so.[0-9]*" 2>/dev/null | sort -V | tail -n 1)
        fi
        
        if [ -f "$ASAN_LIB" ]; then
            export LD_PRELOAD="$ASAN_LIB"
            echo -e "Using ASAN_LIB: $ASAN_LIB"
        fi

        # Exception handling configuration
        ASAN_OPTS="abort_on_error=1:symbolize=1"
        if [[ "$DRIVER" == "duckdb" || "$DRIVER" == "firebird" ]]; then
            ASAN_OPTS="intercept_exceptions=0:verify_asan_link_order=0:$ASAN_OPTS"
        else
            ASAN_OPTS="intercept_exceptions=1:$ASAN_OPTS"
        fi
        export ASAN_OPTIONS="$ASAN_OPTS"
        
        lua test.lua "$DRIVER" "$DB_DS" "$DB_UN" "$DB_PW" "$DB_HO" "$DB_PO"
        RET=$?
        unset LD_PRELOAD
        ;;
    *)
        echo -e "${RED}Unknown mode: $MODE${NC}"
        exit 1
        ;;
esac

exit $RET
