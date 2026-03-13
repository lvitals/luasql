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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

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
    firebird) export DB_HOST="$DB_HOST_FIREBIRD" ;;
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
