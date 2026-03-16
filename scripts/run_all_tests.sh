#!/bin/bash

# Ensure we are in the project root
cd "$(dirname "$0")/.."
PROJECT_ROOT=$(pwd)

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}             LUASQL FULL TEST & INSTALL SUITE                   ${NC}"
echo -e "${BLUE}================================================================${NC}"

# Function to wait for DB
wait_for_db() {
    local host=$1
    local port=$2
    echo -n "Waiting for $host:$port... "
    while ! timeout 1s bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null; do
        sleep 2
    done
    echo -e "${GREEN}Ready!${NC}"
}

if [ "$RUNNING_IN_DOCKER" == "1" ]; then
    export LUA_INC_DIR="/usr/include/lua5.4"
    wait_for_db $DB_HOST_POSTGRES 5432
    wait_for_db $DB_HOST_MYSQL 3306
    wait_for_db $DB_HOST_FIREBIRD 3050
    
    # Setup environment
    export PGHOST=$DB_HOST_POSTGRES
    export PGUSER=$DB_USER
    export PGPASSWORD=$DB_PASS
    export PGDATABASE=$DB_NAME
    export MYSQL_HOST=$DB_HOST_MYSQL
    export MYSQL_PWD=$DB_PASS
fi

# 2. Setup Driver environment for Makefile
export LUA_INC="/usr/include/lua5.4"
# Variables used by Makefile: DRIVER_INCS_<driver> and DRIVER_LIBS_<driver>
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

# 3. Install drivers via LuaRocks
echo -e "\n${YELLOW}>>> Installing drivers via luarocks make...${NC}"
ROCKS=(
    "rockspec/luasql-sqlite3-2.8.0-1.rockspec"
    "rockspec/luasql-postgres-2.8.0-1.rockspec"
    "rockspec/luasql-mysql-2.8.0-1.rockspec"
    "rockspec/luasql-duckdb-2.8.0-1.rockspec"
    "rockspec/luasql-odbc-2.8.1-1.rockspec"
    "rockspec/luasql-firebird-2.8.0-1.rockspec"
)

for r in "${ROCKS[@]}"; do
    if [ -f "$r" ]; then
        echo -e "Installing ${BLUE}$r${NC}..."
        luarocks --lua-version 5.4 make "$r" \
            LUA_INCDIR="/usr/include/lua5.4" \
            MYSQL_INCDIR="/usr/include/mysql" \
            PGSQL_INCDIR="/usr/include/postgresql" > /tmp/luarocks_build.log 2>&1
        if [ $? -eq 0 ]; then
            echo -e "  ${GREEN}Successfully installed.${NC}"
        else
            echo -e "  ${RED}Failed to install.${NC}"
        fi
    fi
done

# 4. Run Leak Detection (Valgrind)
echo -e "\n${YELLOW}>>> RUNNING VALGRIND LEAK DETECTION${NC}"
./scripts/check_leaks.sh

# 5. Run ASAN Analysis
echo -e "\n${YELLOW}>>> RUNNING ASAN ANALYSIS${NC}"
export ASAN_OPTIONS="abort_on_error=0:symbolize=1:handle_segv=0:handle_sigill=0:verify_asan_link_order=0:intercept_exceptions=0"
./scripts/check_asan.sh

# 6. Run Performance Tests
echo -e "\n${YELLOW}>>> RUNNING PERFORMANCE TESTS${NC}"
if [ -f "tests/performance_async.lua" ]; then
    echo -e "Benchmarking sqlite3..."
    lua tests/performance_async.lua sqlite3

    if [ "$RUNNING_IN_DOCKER" == "1" ]; then
        echo -e "Benchmarking mysql..."
        DB_HOST=$DB_HOST_MYSQL DB_USER=luasql DB_PASS=luasql lua tests/performance_async.lua mysql
        echo -e "Benchmarking postgres..."
        DB_HOST=$DB_HOST_POSTGRES DB_USER=luasql DB_PASS=luasql lua tests/performance_async.lua postgres
    fi
fi

# 7. Final Cleanup
echo -e "\n${YELLOW}>>> Reverting all patches...${NC}"
for (( i=${#APPLIED_PATCHES[@]}-1; i>=0; i-- )); do
    p=${APPLIED_PATCHES[$i]}
    echo -n "Reverting $p... "
    patch -R -p0 < "$p" > /dev/null
    echo -e "${GREEN}OK${NC}"
done

echo -e "\n${GREEN}================================================================${NC}"
echo -e "${GREEN}                  ALL TASKS COMPLETED                           ${NC}"
echo -e "${GREEN}================================================================${NC}"
