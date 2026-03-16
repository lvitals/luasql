#!/bin/bash
# ==============================================================================
# LuaSQL Async Performance Test Runner
# ------------------------------------------------------------------------------
# This script runs the asynchronous performance test for a specific driver.
#
# Usage: ./scripts/run_async_test.sh <driver>
# Examples:
#   ./scripts/run_async_test.sh sqlite3
#   ./scripts/run_async_test.sh postgres
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

DRIVER=$1

if [ -z "$DRIVER" ]; then
    echo -e "${RED}Error: No driver specified.${NC}"
    echo -e "Usage: $0 <driver>"
    exit 1
fi

echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}Running Async Benchmark for driver: ${BOLD}[$DRIVER]${NC}"
echo -e "${BLUE}================================================================${NC}"

# Connection parameters from env or defaults
export LUA_INC="/usr/include/lua5.4"
export LUA_CPATH="$PROJECT_ROOT/src/?.so;;"

# Database config setup
export DB_NAME=${DB_NAME:-luasql_test}
export DB_USER=${DB_USER:-luasql}
export DB_PASS=${DB_PASS:-luasql}

case "$DRIVER" in
    postgres) export DB_HOST="$DB_HOST_POSTGRES" ;;
    mysql)    export DB_HOST="$DB_HOST_MYSQL" ;;
    firebird)
        export DB_HOST="$DB_HOST_FIREBIRD"
        if [[ "$FIREBIRD_VERSION" == "v5"* || "$FIREBIRD_VERSION" == "5.0"* ]]; then
            export DB_NAME="/firebird/data/luasql_test"
        else
            export DB_NAME="luasql_test"
        fi
        ;;
    oci8)     export DB_HOST="$DB_HOST_ORACLE" ;;
    odbc)
        export DB_HOST="$DB_HOST_POSTGRES"
        # Setup Postgres ODBC for testing
        DRIVER_PATH=$(find /usr/lib -name "psqlodbcw.so" | head -n 1)
        if [ -n "$DRIVER_PATH" ]; then
            cat <<EOF > /etc/odbcinst.ini
[PostgreSQL]
Description = PostgreSQL ODBC driver (Unicode)
Driver      = $DRIVER_PATH
EOF
            cat <<EOF > /etc/odbc.ini
[luasql_test]
Driver              = PostgreSQL
Servername          = ${DB_HOST:-db-postgres}
Port                = 5432
Database            = $DB_NAME
EOF
        fi
        ;;
    *) ;;
esac

# Wait for database if running in Docker
if [ "$RUNNING_IN_DOCKER" == "1" ]; then
    case "$DRIVER" in
        postgres) wait_for_db "$DB_HOST_POSTGRES" 5432 || exit 1 ;;
        mysql)    wait_for_db "$DB_HOST_MYSQL" 3306 || exit 1 ;;
        firebird) wait_for_db "$DB_HOST_FIREBIRD" 3050 || exit 1 ;;
        oci8)
            wait_for_db "$DB_HOST_ORACLE" 1521 || exit 1
            echo -e "${YELLOW}Waiting for Oracle service FREEPDB1 to be ready (this can take up to 10 minutes)...${NC}"
            for i in {1..60}; do
                # Try to connect using sqlplus to verify service availability
                if echo "exit" | sqlplus -L system/luasql@${DB_HOST_ORACLE}/FREEPDB1 > /dev/null 2>&1; then
                    echo -e "${GREEN}Ready!${NC}"
                    break
                fi
                [ $((i % 5)) -eq 0 ] && echo "Still waiting for FREEPDB1 ($((i * 10))s)..."
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

# Compilation flags
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

echo -e "${YELLOW}Building driver $DRIVER...${NC}"
make clean > /dev/null
if ! make "$DRIVER" OPTFLAGS="-g -O2" > /tmp/build_async.log 2>&1; then
    echo -e "${RED}Build failed! See /tmp/build_async.log${NC}"
    cat /tmp/build_async.log
    exit 1
fi
echo -e "${GREEN}Build successful.${NC}"

# Setup symlink
mkdir -p src/luasql
ln -sf "../$DRIVER.so" "src/luasql/$DRIVER.so"

echo -e "${YELLOW}Starting benchmark script...${NC}\n"
lua tests/performance_async.lua "$DRIVER"
RET=$?

echo -e "\n${BLUE}================================================================${NC}"
if [ $RET -eq 0 ]; then
    echo -e "${GREEN}${BOLD}BENCHMARK COMPLETED${NC}"
else
    echo -e "${RED}${BOLD}BENCHMARK FAILED${NC}"
fi
echo -e "${BLUE}================================================================${NC}"

exit $RET
