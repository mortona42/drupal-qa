#!/usr/bin/env bash
# DDEV interoperability.
#
# The temptation is to `ddev exec` everything, but that is the slow path: every
# phpcs run pays Docker's process-start cost, and the container needs the QA
# tools installed in it. The arrangement here is the other way round — tools run
# natively from the Nix store at host speed, and only the *services* come from
# DDEV: its database for tests that need MariaDB, and its URL as the base URL for
# functional tests. That keeps the fast feedback loop fast and still lets a test
# exercise the same stack the site really runs on.
# shellcheck shell=bash

ddev_available() {
  [[ -n "${QA_DDEV_ROOT:-}" ]] && command -v ddev >/dev/null 2>&1
}

ddev_running() {
  ddev_available || return 1
  local state
  state=$(ddev describe -j 2>/dev/null | jq -r '.raw.status // empty' 2>/dev/null)
  [[ "$state" == "running" ]]
}

ddev_describe() {
  ddev describe -j 2>/dev/null
}

# Build a SIMPLETEST_DB URL pointing at DDEV's database on its published host
# port, so host-native PHPUnit can talk to it directly.
ddev_db_url() {
  local json; json=$(ddev_describe) || return 1
  local port user pass name type
  port=$(jq -r '.raw.dbinfo.published_port // empty' <<< "$json")
  user=$(jq -r '.raw.dbinfo.username // "db"' <<< "$json")
  pass=$(jq -r '.raw.dbinfo.password // "db"' <<< "$json")
  name=$(jq -r '.raw.dbinfo.dbname // "db"' <<< "$json")
  type=$(jq -r '.raw.dbinfo.database_type // "mariadb"' <<< "$json")
  [[ -z "$port" || "$port" == "null" ]] && return 1

  local scheme=mysql
  [[ "$type" == postgres* ]] && scheme=pgsql
  printf '%s://%s:%s@127.0.0.1:%s/%s' "$scheme" "$user" "$pass" "$port" "$name"
}

ddev_base_url() {
  local json; json=$(ddev_describe) || return 1
  jq -r '.raw.primary_url // empty' <<< "$json"
}

# Fold DDEV's services into the test environment. Called from cmd_test when
# --ddev is passed or when --db=ddev is selected.
use_ddev_services() {
  ddev_available || die "--ddev was requested but no .ddev/config.yaml was found above $QA_TARGET_PATH."
  if ! ddev_running; then
    warn "The DDEV project is not running. Start it with: ddev start"
    die "Cannot borrow DDEV's database while the project is stopped."
  fi

  local url; url=$(ddev_db_url) || die "Could not read DDEV's database connection details."
  QA_DB_URL=$url
  QA_DB=external
  info "Using DDEV's database on the published host port."

  local base; base=$(ddev_base_url)
  if [[ -n "$base" ]]; then
    QA_DDEV_BASE_URL=$base
    info "Using DDEV's web server: $base"
  fi
  export QA_DB QA_DB_URL QA_DDEV_BASE_URL
}

# Write a DDEV host command so `ddev qa ...` reaches this tool. Host commands run
# outside the container, which is exactly what we want.
install_ddev_command() {
  ddev_available || die "No .ddev directory found above $QA_TARGET_PATH."
  local dir="$QA_DDEV_ROOT/.ddev/commands/host"
  mkdir -p "$dir"
  cat > "$dir/qa" <<'CMD'
#!/usr/bin/env bash
## Description: Run Drupal code quality tools and tests (drupal-qa, on the host)
## Usage: qa [command] [target] [flags]
## Example: "ddev qa lint my_module"\n"ddev qa test my_module --type=kernel"\n"ddev qa fix --changed"

# Runs on the host, not in the web container: the QA tools come from Nix and are
# much faster outside Docker. DDEV's database and URL are still used for tests.
if command -v drupal-qa >/dev/null 2>&1; then
  exec drupal-qa "$@"
fi
if command -v nix >/dev/null 2>&1; then
  exec nix run "${DRUPAL_QA_FLAKE:-github:your-org/drupal-nix-tools}" -- "$@"
fi
echo "drupal-qa is not on PATH. Enter the dev shell with 'nix develop', or install it with 'nix profile install'." >&2
exit 1
CMD
  chmod +x "$dir/qa"
  info "Installed DDEV command: ${dir/#$QA_DDEV_ROOT\//}"
  info "Run 'ddev restart' (or 'ddev debug fix-commands'), then try: ddev qa lint"
}
