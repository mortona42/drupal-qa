#!/usr/bin/env bash
# PHPUnit and Nightwatch.
#
# Unlike the lint jobs, tests need a real Drupal site: an autoloader that matches
# core, a database, and for FunctionalJavascript a web server and a browser.
# Rather than demanding the developer set six environment variables by hand, this
# stands the missing pieces up itself:
#
#   * database  - SQLite in a temp dir by default. Unit and Kernel tests need no
#                 server at all, and Functional tests run fine on it.
#   * webserver - PHP's built-in server with core's .ht.router.php.
#   * browser   - the chromedriver pinned by this flake, headless.
#
# Any of those can be replaced by pointing at DDEV instead (--ddev), which is the
# right choice when the test depends on the real MariaDB or on installed modules.
# shellcheck shell=bash

QA_CLEANUP_PIDS=()
QA_CLEANUP_DIRS=()

cleanup_test_env() {
  local pid dir
  for pid in "${QA_CLEANUP_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  if [[ "${QA_KEEP_ARTIFACTS:-0}" != "1" ]]; then
    for dir in "${QA_CLEANUP_DIRS[@]}"; do
      [[ -n "$dir" && -d "$dir" && "$dir" == /tmp/* ]] && rm -rf "$dir"
    done
  elif [[ ${#QA_CLEANUP_DIRS[@]} -gt 0 ]]; then
    info "Kept test scratch: ${QA_CLEANUP_DIRS[0]}"
  fi
}

require_drupal_root() {
  [[ -n "${QA_DRUPAL_ROOT:-}" ]] || die "No Drupal root found. Tests need an installed Drupal codebase; pass --core=<path> or run inside one."
  [[ -f "$QA_COMPOSER_ROOT/vendor/autoload.php" ]] || die "No vendor/autoload.php under $QA_COMPOSER_ROOT. Run 'composer install' in the Drupal project first."
}

# PHPUnit must be the one that matches core: core/tests/bootstrap.php and the
# listeners in core's phpunit.xml.dist are version-coupled. Never substitute the
# toolbox copy here.
find_phpunit() {
  local candidates=(
    "$QA_COMPOSER_ROOT/vendor/bin/phpunit"
    "$QA_DRUPAL_ROOT/../vendor/bin/phpunit"
    "$QA_DRUPAL_ROOT/vendor/bin/phpunit"
  )
  local c
  for c in "${candidates[@]}"; do
    [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# Wait for a TCP port to accept connections, so we never race the server.
wait_for_port() {
  local host=$1 port=$2 timeout=${3:-20} i
  for ((i = 0; i < timeout * 10; i++)); do
    if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
      exec 3<&- 3>&-
      return 0
    fi
    sleep 0.1
  done
  return 1
}

free_port() {
  local port
  for ((port = ${1:-8888}; port < ${1:-8888} + 200; port++)); do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      printf '%s' "$port"; return 0
    fi
    exec 3<&- 3>&- 2>/dev/null || true
  done
  return 1
}

start_webserver() {
  local root=$1 port
  port=$(free_port 8888) || die "No free port for the test web server."
  local router="$root/.ht.router.php"
  local -a cmd
  if [[ -f "$router" ]]; then
    cmd=("$(resolve_php)" -d max_execution_time=0 -S "127.0.0.1:$port" -t "$root" "$router")
  else
    cmd=("$(resolve_php)" -d max_execution_time=0 -S "127.0.0.1:$port" -t "$root")
  fi
  debug "web server: ${cmd[*]}"
  # PHP's built-in server handles one request at a time unless told otherwise.
  # Drupal pages issue sub-requests to themselves (big_pipe, AJAX, image
  # derivatives), and a single-worker server deadlocks on the first one.
  PHP_CLI_SERVER_WORKERS=${QA_SERVER_WORKERS:-8} \
    "${cmd[@]}" >"${QA_TEST_SCRATCH}/webserver.log" 2>&1 &
  QA_CLEANUP_PIDS+=($!)
  wait_for_port 127.0.0.1 "$port" 20 || die "Test web server did not start; see ${QA_TEST_SCRATCH}/webserver.log"
  printf 'http://127.0.0.1:%s' "$port"
}

start_chromedriver() {
  local bin=${DRUPAL_QA_CHROMEDRIVER:-}
  [[ -z "$bin" ]] && bin=$(command -v chromedriver 2>/dev/null)
  [[ -n "$bin" && -x "$bin" ]] || die "chromedriver not found; FunctionalJavascript tests need it."
  local port
  port=$(free_port 9515) || die "No free port for chromedriver."
  debug "chromedriver: $bin --port=$port"
  "$bin" --port="$port" --allowed-ips=127.0.0.1 --allowed-origins='*' >"${QA_TEST_SCRATCH}/chromedriver.log" 2>&1 &
  QA_CLEANUP_PIDS+=($!)
  wait_for_port 127.0.0.1 "$port" 20 || die "chromedriver did not start; see ${QA_TEST_SCRATCH}/chromedriver.log"
  printf '%s' "$port"
}

# Build the SIMPLETEST_DB URL. SQLite is the default because it needs nothing
# running; MySQL/Postgres are used when the developer asked for them or when we
# are borrowing DDEV's database.
build_db_url() {
  case "${QA_DB:-sqlite}" in
    sqlite)
      local file="$QA_TEST_SCRATCH/test.sqlite"
      printf 'sqlite://localhost/%s' "$file"
      ;;
    mysql|mariadb)
      printf '%s' "${QA_DB_URL:-mysql://db:db@127.0.0.1:3306/db}"
      ;;
    pgsql|postgres|postgresql)
      printf '%s' "${QA_DB_URL:-pgsql://db:db@127.0.0.1:5432/db}"
      ;;
    *)
      printf '%s' "${QA_DB_URL:-${QA_DB}}"
      ;;
  esac
}

# Map a friendly test type onto the PSR-4 directory Drupal puts it in.
#
# Selecting by directory rather than by --testsuite is deliberate. Core's
# testsuites are defined by globs rooted at the Drupal root; passing both a
# testsuite and a path argument means the path wins, so `--type=unit` would
# quietly run the Kernel and Functional tests too.
test_dir_for() {
  case "$1" in
    unit)        printf 'Unit' ;;
    kernel)      printf 'Kernel' ;;
    functional)  printf 'Functional' ;;
    functional-js|js|functionaljavascript) printf 'FunctionalJavascript' ;;
    build)       printf 'Build' ;;
    *)           printf '%s' "$1" ;;
  esac
}

# Does this type exist in the target at all?
test_type_present() {
  [[ -d "$QA_PROJECT_ROOT/tests/src/$(test_dir_for "$1")" ]]
}

# Collect the directories to hand PHPUnit for the requested types. Types the
# target has no tests for are reported rather than silently dropped, because
# "0 tests ran" looks like success and is how a broken selector goes unnoticed.
resolve_test_paths() {
  local types=$1 t dir
  QA_TEST_PATHS=()
  local missing=""
  IFS=, read -ra list <<< "$types"
  for t in "${list[@]}"; do
    dir="$QA_PROJECT_ROOT/tests/src/$(test_dir_for "$t")"
    if [[ -d "$dir" ]]; then
      QA_TEST_PATHS+=("$dir")
    else
      missing+=" $t"
    fi
  done
  [[ -n "$missing" ]] && warn "No tests of type(s):$missing in ${QA_PROJECT_ROOT##*/}"
  [[ ${#QA_TEST_PATHS[@]} -gt 0 ]]
}

cmd_test() {
  require_drupal_root

  local phpunit
  phpunit=$(find_phpunit) || die "No phpunit binary found. Install dev dependencies: composer require --dev drupal/core-dev --with-all-dependencies"

  QA_TEST_SCRATCH=$(mktemp -d /tmp/drupal-qa-test.XXXXXX)
  QA_CLEANUP_DIRS+=("$QA_TEST_SCRATCH")
  trap cleanup_test_env EXIT INT TERM

  local types=${QA_TEST_TYPES:-}
  local needs_browser=0 needs_server=0

  # Work out which directories will actually be run, then what infrastructure
  # those need. A plain unit-test run must not pay for a browser it will never
  # open, and equally must not skip the web server a Functional test requires.
  QA_TEST_PATHS=()
  if [[ -n "$types" ]]; then
    resolve_test_paths "$types" || { record_result phpunit skip "no tests of the requested type"; return 0; }
  elif [[ -n "${QA_TARGET_FILE:-}" ]]; then
    QA_TEST_PATHS=("$QA_TARGET_FILE")
  elif [[ -d "$QA_PROJECT_ROOT/tests" ]]; then
    QA_TEST_PATHS=("$QA_PROJECT_ROOT/tests")
  else
    QA_TEST_PATHS=("$QA_PROJECT_ROOT")
  fi

  local p
  for p in "${QA_TEST_PATHS[@]}"; do
    case $p in
      */FunctionalJavascript*) needs_server=1; needs_browser=1 ;;
      */Functional*)           needs_server=1 ;;
      */Build*)                needs_server=1 ;;
    esac
  done
  # A whole-directory or single-file run: look at what is really in there.
  if [[ -z "$types" ]]; then
    test_type_present functional && needs_server=1
    test_type_present functional-js && { needs_server=1; needs_browser=1; }
    test_type_present build && needs_server=1
  fi

  # Borrow DDEV's services when asked. Everything still executes on the host.
  [[ "${QA_USE_DDEV:-0}" == "1" ]] && use_ddev_services

  local db_url base_url
  db_url=$(build_db_url)
  # Never print the password back at the user.
  info "Database: $(sed -E 's#://[^@]*@#://***@#' <<< "${db_url%%\?*}")"

  if [[ $needs_server -eq 1 ]]; then
    if [[ -n "${QA_DDEV_BASE_URL:-}" ]]; then
      base_url=$QA_DDEV_BASE_URL
      info "Web server: $base_url (DDEV)"
    else
      base_url=$(start_webserver "$QA_DRUPAL_ROOT")
      info "Web server: $base_url"
    fi
  else
    base_url="http://127.0.0.1"
  fi

  # When a failing Functional test dumps a page, Drupal prints a URL built from
  # BROWSERTEST_OUTPUT_BASE_URL plus the file's path relative to the Drupal root.
  # Writing the dumps anywhere else produces a link that 404s, so use Drupal's
  # own sites/simpletest location (which core already gitignores) whenever it is
  # writable, and fall back to the scratch directory when it is not.
  local output_dir="$QA_DRUPAL_ROOT/sites/simpletest/browser_output"
  if ! mkdir -p "$output_dir" 2>/dev/null; then
    output_dir="$QA_TEST_SCRATCH/browser_output"
    mkdir -p "$output_dir"
  fi
  QA_BROWSER_OUTPUT_DIR=$output_dir

  local -a env_args=(
    "SIMPLETEST_DB=$db_url"
    "SIMPLETEST_BASE_URL=$base_url"
    "BROWSERTEST_OUTPUT_DIRECTORY=$output_dir"
    "BROWSERTEST_OUTPUT_BASE_URL=$base_url"
    "SYMFONY_DEPRECATIONS_HELPER=${QA_DEPRECATIONS:-weak}"
  )

  if [[ $needs_browser -eq 1 ]]; then
    local cd_port; cd_port=$(start_chromedriver)
    info "chromedriver: http://127.0.0.1:$cd_port"
    local chrome_bin=${DRUPAL_QA_CHROME:-}
    local chrome_args='["--headless=new","--disable-gpu","--no-sandbox","--disable-dev-shm-usage","--window-size=1920,1080"]'
    local binary_json=""
    [[ -n "$chrome_bin" ]] && binary_json=",\"binary\":\"$chrome_bin\""
    env_args+=("MINK_DRIVER_ARGS_WEBDRIVER=[\"chrome\",{\"browserName\":\"chrome\",\"goog:chromeOptions\":{\"args\":$chrome_args$binary_json}},\"http://127.0.0.1:$cd_port\"]")
  fi

  # Core's phpunit.xml is the source of truth for bootstrap and listeners. A
  # project that has made its own copy at core/phpunit.xml has customised it
  # deliberately, so use that untouched; otherwise derive a runnable version of
  # phpunit.xml.dist in the cache directory rather than writing into the
  # checkout the way Drupal's CI does.
  local config
  if [[ -f "$QA_DRUPAL_ROOT/core/phpunit.xml" ]]; then
    config="$QA_DRUPAL_ROOT/core/phpunit.xml"
    debug "using the project's own core/phpunit.xml"
  elif [[ -f "$QA_DRUPAL_ROOT/core/phpunit.xml.dist" ]]; then
    config="$(cache_dir)/phpunit.xml"
    local -a prep=()
    [[ -n "${QA_COVERAGE_DRIVER:-}" && "${QA_COVERAGE_DRIVER}" != "none" ]] && prep+=(--coverage)
    [[ "${QA_SHOW_DEPRECATIONS:-0}" == "1" ]] && prep+=(--deprecations)
    "$(resolve_php)" "$(assets_dir)/prepare-phpunit-xml.php" \
      "$QA_DRUPAL_ROOT/core/phpunit.xml.dist" "$QA_DRUPAL_ROOT/core" "$config" "${prep[@]}" \
      || die "Could not prepare a PHPUnit configuration from core/phpunit.xml.dist."
  else
    die "No core/phpunit.xml.dist under $QA_DRUPAL_ROOT."
  fi

  local -a args=(--configuration "$config")
  [[ -n "${QA_TEST_GROUP:-}" ]] && args+=(--group "$QA_TEST_GROUP")
  [[ -n "${QA_TEST_FILTER:-}" ]] && args+=(--filter "$QA_TEST_FILTER")
  [[ "${QA_TEST_STOP:-0}" == "1" ]] && args+=(--stop-on-failure)
  case "${QA_FORMAT:-pretty}" in
    junit) args+=(--log-junit "${QA_REPORT_DIR:-$PWD}/phpunit-junit.xml") ;;
    *)     args+=(--testdox) ;;
  esac
  if [[ -n "${QA_COVERAGE_DRIVER:-}" && "${QA_COVERAGE_DRIVER}" != "none" ]]; then
    args+=(--coverage-text --coverage-html "${QA_REPORT_DIR:-$PWD}/coverage")
  fi
  [[ -n "${QA_EXTRA_PHPUNIT:-}" ]] && read -ra extra <<< "$QA_EXTRA_PHPUNIT" && args+=("${extra[@]}")

  local shown=""
  for p in "${QA_TEST_PATHS[@]}"; do
    shown+="${shown:+, }${p/#$QA_DRUPAL_ROOT\//}"
  done
  info "Running $(basename "$phpunit") on $shown"

  local status=pass
  ( cd "$QA_DRUPAL_ROOT/core" && run_cmd env "${env_args[@]}" "$phpunit" "${args[@]}" "${QA_TEST_PATHS[@]}" ) || status=fail

  local -a browser_files=("$QA_BROWSER_OUTPUT_DIR"/*)
  if [[ "$status" == fail && -e "${browser_files[0]}" ]]; then
    QA_KEEP_ARTIFACTS=1
    warn "Page dumps from the failing tests are in $QA_BROWSER_OUTPUT_DIR"
  fi

  record_result phpunit "$status"
}

cmd_nightwatch() {
  require_drupal_root
  local dir="$QA_DRUPAL_ROOT/core"
  [[ -f "$dir/tests/Drupal/Nightwatch/nightwatch.conf.js" ]] || die "Core does not provide Nightwatch config at $dir."
  [[ -d "$dir/node_modules" ]] || die "Nightwatch needs core's node_modules. Run 'yarn install' in $dir first."

  QA_TEST_SCRATCH=$(mktemp -d /tmp/drupal-qa-nightwatch.XXXXXX)
  QA_CLEANUP_DIRS+=("$QA_TEST_SCRATCH")
  trap cleanup_test_env EXIT INT TERM

  [[ "${QA_USE_DDEV:-0}" == "1" ]] && use_ddev_services
  local base_url
  if [[ -n "${QA_DDEV_BASE_URL:-}" ]]; then
    base_url=$QA_DDEV_BASE_URL
  else
    base_url=$(start_webserver "$QA_DRUPAL_ROOT")
  fi
  local cd_port; cd_port=$(start_chromedriver)

  local -a nw_env=(
    "DRUPAL_TEST_BASE_URL=$base_url"
    "DRUPAL_TEST_DB_URL=$(build_db_url)"
    "DRUPAL_TEST_WEBDRIVER_HOSTNAME=127.0.0.1"
    "DRUPAL_TEST_WEBDRIVER_PORT=$cd_port"
    "DRUPAL_TEST_WEBDRIVER_CHROME_ARGS=--headless=new --disable-gpu --no-sandbox"
    "DRUPAL_TEST_CHROMEDRIVER_AUTOSTART=false"
    "DRUPAL_NIGHTWATCH_OUTPUT=$QA_TEST_SCRATCH/nightwatch_output"
  )
  local -a nw_args=(--config ./tests/Drupal/Nightwatch/nightwatch.conf.js)
  [[ -n "${QA_TEST_FILTER:-}" ]] && nw_args+=(--filter "$QA_TEST_FILTER")
  [[ -n "${QA_EXTRA_NIGHTWATCH:-}" ]] && read -ra extra <<< "$QA_EXTRA_NIGHTWATCH" && nw_args+=("${extra[@]}")

  local status=pass
  ( cd "$dir" && run_cmd env "${nw_env[@]}" \
      "${DRUPAL_QA_NODE:-node}" ./node_modules/.bin/nightwatch "${nw_args[@]}" ) || status=fail
  record_result nightwatch "$status"
}
