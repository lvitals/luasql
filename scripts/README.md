# LuaSQL Test and Analysis Suite

This directory contains the automation scripts for building, testing, and analyzing LuaSQL drivers. These scripts are designed to run within the provided Docker/Podman environment.

## Core Scripts

### 1. run_all_tests.sh
The main entry point for the CI/CD pipeline and the default command for the `test-runner` service.
- **Purpose**: Executes the full test lifecycle:
    1. Applies infrastructure and memory patches.
    2. Installs all drivers via LuaRocks.
    3. Runs Valgrind leak detection for all drivers.
    4. Runs ASAN analysis for all drivers.
    5. Executes performance benchmarks.
- **Usage**: Triggered by `podman-compose up test-runner`.

### 2. run_test.sh
A specialized script for granular testing of a single driver.
- **Purpose**: Build and execute tests for a specific driver in a chosen mode.
- **Usage**: `./scripts/run_test.sh <driver> [mode]`
- **Arguments**:
    - `<driver>`: The driver name (e.g., `mysql`, `postgres`, `sqlite3`, `duckdb`, `firebird`).
    - `[mode]`:
        - `test` (default): Functional tests.
        - `valgrind`: Memory leak detection using Valgrind.
        - `asan`: Memory error analysis using AddressSanitizer.
- **Example**: `podman-compose run --rm test-runner ./scripts/run_test.sh mysql valgrind`

### 3. check_leaks.sh
Batch leak detection script.
- **Purpose**: Runs Valgrind on multiple drivers and generates a summary report.
- **Usage**: `./scripts/check_leaks.sh [driver]`

### 4. check_asan.sh
Batch ASAN analysis script.
- **Purpose**: Runs AddressSanitizer analysis on multiple drivers and generates a summary report.
- **Usage**: `./scripts/check_asan.sh [driver]`

---

## Practical Command Examples

All commands should be executed through `podman-compose` to ensure database services are available.

### Run everything
```bash
podman-compose up test-runner
```

### Run a specific functional test
```bash
podman-compose run --rm test-runner ./scripts/run_test.sh postgres
```

### Run Valgrind on a specific driver
```bash
podman-compose run --rm test-runner ./scripts/run_test.sh sqlite3 valgrind
```

### Run ASAN on a specific driver
```bash
podman-compose run --rm test-runner ./scripts/run_test.sh duckdb asan
```

---

## Environment Configuration

The scripts automatically utilize the following environment variables defined in `compose.yml`:
- `DB_NAME`: Target database name.
- `DB_USER`: Database user.
- `DB_PASS`: Database password.
- `DB_HOST_POSTGRES`: PostgreSQL container hostname.
- `DB_HOST_MYSQL`: MySQL/MariaDB container hostname.
- `DB_HOST_FIREBIRD`: Firebird container hostname.
