#!/usr/bin/env bash
# Logging, environment detection, and target resolution.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [[ -t 1 && "${NO_COLOR:-}" == "" && "${DRUPAL_QA_COLOR:-auto}" != "never" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
fi

log()    { printf '%s\n' "$*" >&2; }
info()   { printf '%s==>%s %s\n' "$C_BLUE$C_BOLD" "$C_RESET" "$*" >&2; }
warn()   { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error()  { printf '%serror:%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$*" >&2; }
debug()  { [[ "${QA_VERBOSE:-0}" == "1" ]] && printf '%s  %s%s\n' "$C_DIM" "$*" "$C_RESET" >&2; return 0; }
die()    { error "$*"; exit 1; }

# Remember, and optionally show, the exact command being run, so that any
# disagreement between this wrapper and the tool underneath can be settled by
# hand. The full command lines are long enough to drown the actual findings, so
# they are shown on request (-v) and always recoverable afterwards.
QA_LAST_CMD=""
run_cmd() {
  QA_LAST_CMD=$*
  if [[ "${QA_VERBOSE:-0}" == "1" || "${QA_SHOW_COMMANDS:-0}" == "1" ]]; then
    printf '%s$ %s%s\n' "$C_DIM" "$*" "$C_RESET" >&2
  fi
  "$@"
}

# ---------------------------------------------------------------------------
# Result accounting
#
# Every tool reports through here so the run ends with one honest summary
# instead of the caller having to scroll back through thousands of lines.
# ---------------------------------------------------------------------------

QA_RESULT_NAMES=()
QA_RESULT_STATUS=()
QA_RESULT_NOTES=()

record_result() {
  local name=$1 status=$2 note=${3:-}
  QA_RESULT_NAMES+=("$name")
  QA_RESULT_STATUS+=("$status")
  QA_RESULT_NOTES+=("$note")
}

# status values: pass | fail | skip | warn
print_summary() {
  local i failed=0 total=${#QA_RESULT_NAMES[@]}
  [[ $total -eq 0 ]] && return 0

  printf '\n%s%s%s\n' "$C_BOLD" "── Summary ───────────────────────────────────────────" "$C_RESET" >&2
  for ((i = 0; i < total; i++)); do
    local name=${QA_RESULT_NAMES[$i]} status=${QA_RESULT_STATUS[$i]} note=${QA_RESULT_NOTES[$i]}
    local mark colour
    case $status in
      pass) mark='pass'; colour=$C_GREEN ;;
      fail) mark='FAIL'; colour=$C_RED; failed=$((failed + 1)) ;;
      warn) mark='warn'; colour=$C_YELLOW ;;
      skip) mark='skip'; colour=$C_DIM ;;
      *)    mark=$status; colour='' ;;
    esac
    printf '  %s%-6s%s %-16s %s%s%s\n' "$colour" "$mark" "$C_RESET" "$name" "$C_DIM" "$note" "$C_RESET" >&2
  done
  printf '\n' >&2

  if [[ $failed -gt 0 ]]; then
    printf '%s%d check(s) failed.%s Re-run one on its own with %sdrupal-qa <tool> %s%s, or add %s-v%s to see the exact commands.\n\n' \
      "$C_RED$C_BOLD" "$failed" "$C_RESET" "$C_CYAN" "${QA_TARGET_ARG:-.}" "$C_RESET" "$C_CYAN" "$C_RESET" >&2
    return 1
  fi
  printf '%sAll checks passed.%s\n\n' "$C_GREEN$C_BOLD" "$C_RESET" >&2
  return 0
}

# ---------------------------------------------------------------------------
# PHP selection
#
# Getting this wrong is not a cosmetic problem. When the project's own
# vendor/bin tools are used — which they are whenever the project installs them,
# because they are the version-matched ones — Composer's generated
# platform_check.php aborts with a fatal error if the interpreter is older than
# the installed packages require. Every PHP tool then "fails" for a reason that
# has nothing to do with the code being checked.
#
# So the version is derived from the project rather than from a global default.
# ---------------------------------------------------------------------------

# "80401" -> "8.4"
php_id_to_version() {
  local id=$1
  printf '%d.%d' "$((id / 10000))" "$(((id / 100) % 100))"
}

# "8.4" -> 804, for ordering comparisons.
php_version_rank() {
  local v=$1 major minor
  major=${v%%.*}
  minor=${v#*.}
  minor=${minor%%.*}
  printf '%d' "$((major * 100 + ${minor:-0}))"
}

php_version_available() {
  local var="DRUPAL_QA_PHP_${1//./_}"
  [[ -n "${!var:-}" ]]
}

php_versions_available() {
  local v out=""
  for v in 8.3 8.4 8.5; do
    php_version_available "$v" && out+="${out:+ }$v"
  done
  printf '%s' "$out"
}

# The exact minimum the installed packages enforce at runtime, read from the
# check Composer generates. Authoritative: this is the code that throws.
php_min_from_platform_check() {
  local file="${QA_COMPOSER_ROOT:-}/vendor/composer/platform_check.php"
  [[ -f "$file" ]] || return 1
  local id
  id=$(grep -oE 'PHP_VERSION_ID >= [0-9]+' "$file" | head -1 | grep -oE '[0-9]+$') || return 1
  [[ -n "$id" ]] || return 1
  php_id_to_version "$id"
}

# What the site actually runs under DDEV. ddev merges .ddev/config.*.yaml over
# .ddev/config.yaml, so a later file wins.
php_from_ddev() {
  local root="${QA_DDEV_ROOT:-}"
  [[ -n "$root" && -d "$root/.ddev" ]] || return 1
  local file version=""
  for file in "$root/.ddev/config.yaml" "$root"/.ddev/config.*.yaml; do
    [[ -f "$file" ]] || continue
    local found
    found=$(grep -E '^[[:space:]]*php_version:' "$file" 2>/dev/null | tail -1 | sed -E 's/.*php_version:[[:space:]]*//' | tr -d '"'"'"' ')
    [[ -n "$found" ]] && version=$found
  done
  [[ -n "$version" ]] || return 1
  printf '%s' "$version"
}

php_from_composer() {
  local file="${QA_COMPOSER_ROOT:-}/composer.json"
  [[ -f "$file" ]] || return 1
  local v
  # config.platform.php is what Composer resolved against; require.php is the
  # declared constraint. Take the first version-looking token out of either.
  v=$(jq -r '.config.platform.php // .require.php // empty' "$file" 2>/dev/null) || return 1
  v=$(grep -oE '[0-9]+\.[0-9]+' <<< "$v" | head -1)
  [[ -n "$v" ]] || return 1
  printf '%s' "$v"
}

# Decide once, at target-resolution time, unless --php said otherwise.
detect_php_version() {
  [[ -n "${QA_PHP_EXPLICIT:-}" ]] && return 0

  local preferred="" source="" min=""
  if preferred=$(php_from_ddev); then
    source="DDEV config"
  elif preferred=$(php_from_composer); then
    source="composer.json"
  else
    preferred=${DRUPAL_QA_PHP_DEFAULT:-8.3}
    source="default"
  fi

  # Raise, never lower: the installed packages' hard minimum wins over a
  # preference that would crash on startup.
  if min=$(php_min_from_platform_check); then
    if [[ $(php_version_rank "$min") -gt $(php_version_rank "$preferred") ]]; then
      debug "raising PHP $preferred -> $min (required by vendor/composer/platform_check.php)"
      preferred=$min
      source="required by installed packages"
    fi
  fi

  if ! php_version_available "$preferred"; then
    local have; have=$(php_versions_available)
    # Falling back silently would reintroduce exactly the confusing fatal this
    # detection exists to avoid, so say what happened.
    warn "This project wants PHP $preferred ($source); this build provides $have."
    local candidate best=""
    for candidate in $have; do
      [[ $(php_version_rank "$candidate") -ge $(php_version_rank "$preferred") ]] && { best=$candidate; break; }
    done
    if [[ -n "$best" ]]; then
      warn "Using PHP $best instead."
      preferred=$best
    else
      warn "Using the newest available. PHP tools from the project's vendor/bin may refuse to start."
      preferred=${have##* }
    fi
    source="closest available"
  fi

  QA_PHP_VERSION=$preferred
  QA_PHP_SOURCE=$source
  export QA_PHP_VERSION QA_PHP_SOURCE

  # Put the chosen interpreter first on PATH. Several things we shell out to
  # resolve PHP themselves rather than being handed one: composer, and every
  # vendor/bin script executed through its `#!/usr/bin/env php` shebang. Without
  # this they would silently use whichever PHP the wrapper happened to provide,
  # which is how a correct --php still ends in a platform-check fatal.
  local php_bin; php_bin=$(resolve_php)
  PATH="$(dirname "$php_bin"):$PATH"
  export PATH

  debug "PHP $QA_PHP_VERSION ($QA_PHP_SOURCE) at $php_bin"
}

resolve_php() {
  local version=${QA_PHP_VERSION:-${DRUPAL_QA_PHP_DEFAULT:-8.3}}
  local var="DRUPAL_QA_PHP_${version//./_}"
  local path=${!var:-}

  if [[ -z "$path" ]]; then
    # Outside the Nix wrapper (running from a checkout) fall back to $PATH.
    if command -v php >/dev/null 2>&1; then
      warn "PHP $version is not provided by this build; using $(command -v php)."
      path=$(command -v php)
    else
      die "No PHP $version available. Supported: 8.3, 8.4, 8.5."
    fi
  fi
  printf '%s' "$path"
}

php_run() {
  local php; php=$(resolve_php)
  local -a opts=()
  # Xdebug and pcov both cost real time; only load one when explicitly asked.
  case "${QA_COVERAGE_DRIVER:-none}" in
    pcov)   opts+=(-d pcov.enabled=1 -d pcov.directory="${QA_PROJECT_ROOT:-.}") ;;
    xdebug) opts+=(-d xdebug.mode=coverage) ;;
  esac
  [[ "${QA_XDEBUG:-0}" == "1" ]] && opts+=(-d xdebug.mode=debug -d xdebug.start_with_request=yes -d xdebug.client_host="${QA_XDEBUG_HOST:-127.0.0.1}")
  run_cmd "$php" "${opts[@]}" "$@"
}

# ---------------------------------------------------------------------------
# Toolbox binaries
# ---------------------------------------------------------------------------

# Locate the composer vendor directory inside the Nix-built PHP toolbox.
php_toolbox_vendor() {
  if [[ -n "${QA_PHP_VENDOR_OVERRIDE:-}" ]]; then
    printf '%s' "$QA_PHP_VENDOR_OVERRIDE"; return 0
  fi
  local base=${DRUPAL_QA_PHP_TOOLBOX:-}
  [[ -z "$base" ]] && return 1
  local candidate
  for candidate in "$base"/share/php/*/vendor "$base"/vendor "$base"/libexec/*/vendor; do
    [[ -d "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

# Resolve a PHP QA binary, preferring the project's own vendor/bin when the
# project deliberately pins its own version (a module requiring a specific
# phpstan should get that phpstan), otherwise the pinned toolbox.
php_tool() {
  local name=$1 vendor
  if [[ "${QA_PREFER_PROJECT_TOOLS:-auto}" != "never" && -n "${QA_COMPOSER_BIN_DIR:-}" && -x "$QA_COMPOSER_BIN_DIR/$name" ]]; then
    debug "using project $name from $QA_COMPOSER_BIN_DIR"
    printf '%s' "$QA_COMPOSER_BIN_DIR/$name"; return 0
  fi
  if vendor=$(php_toolbox_vendor) && [[ -f "$vendor/bin/$name" ]]; then
    printf '%s' "$vendor/bin/$name"; return 0
  fi
  command -v "$name" 2>/dev/null && return 0
  return 1
}

# A binary sitting in node_modules/.bin is not proof that it runs. Core's
# node_modules is whatever state the last `yarn install` left it in, and a copy
# installed under an older Node refuses to start ("Unsupported NodeJS version").
# Check before committing to one, so the failure is a clean fallback rather than
# a confusing error attributed to the code being linted.
node_tool_works() {
  [[ -x "$1" ]] || return 1
  "$1" --version >/dev/null 2>&1
}

node_tool_in() {
  local dir=$1 name=$2
  [[ -n "$dir" ]] || return 1
  local bin="$dir/node_modules/.bin/$name"
  node_tool_works "$bin" && { printf '%s' "$bin"; return 0; }
  return 1
}

# Resolve a Node QA binary. The project's own node_modules wins, because a theme
# that installs custom plugins means it; then the pinned toolbox, which is
# known-good; then core's, as a last resort.
#
# Core is deliberately *not* second any more. Its node_modules exists only if
# someone ran `yarn install` in core, and preferring a possibly-stale tree over
# a version-pinned one trades reproducibility for nothing.
node_tool() {
  local name=$1 bin
  for base in "${QA_PROJECT_ROOT:-}" "${DRUPAL_QA_NODE_TOOLBOX:-}" "${QA_DRUPAL_ROOT:-}/core"; do
    bin=$(node_tool_in "$base" "$name") && { printf '%s' "$bin"; return 0; }
  done
  command -v "$name" 2>/dev/null && return 0
  return 1
}

# The directory ESLint/Stylelint should resolve plugins against.
node_modules_root() {
  local dir
  for dir in "${QA_PROJECT_ROOT:-}/node_modules" "${DRUPAL_QA_NODE_TOOLBOX:-}/node_modules" "${QA_DRUPAL_ROOT:-}/core/node_modules"; do
    [[ -n "$dir" && -d "$dir" ]] && { printf '%s' "${dir%/node_modules}"; return 0; }
  done
  return 1
}

# Major version of an ESLint binary. ESLint 8 reads .eslintrc files; ESLint 9
# reads flat config and rejects most of the v8 command-line flags outright, so
# the two cannot be driven the same way.
eslint_major() {
  local v
  v=$("$1" --version 2>/dev/null) || return 1
  v=${v#v}
  printf '%s' "${v%%.*}"
}

# The first base directory offering an ESLint of at least $1.
eslint_base_at_least() {
  local want=$1 base bin major
  for base in "${QA_PROJECT_ROOT:-}" "${QA_DRUPAL_ROOT:-}/core" "${DRUPAL_QA_NODE_TOOLBOX:-}"; do
    bin=$(node_tool_in "$base" eslint) || continue
    major=$(eslint_major "$bin") || continue
    [[ "$major" -ge "$want" ]] && { printf '%s' "$base"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------------------
# Caching
#
# PHPStan, ESLint, Stylelint and CSpell all support result caches. Giving them a
# stable, per-project location turns a 40-second second run into a 2-second one,
# which is the difference between a tool you run on save and one you avoid.
# ---------------------------------------------------------------------------

cache_dir() {
  local base=${XDG_CACHE_HOME:-$HOME/.cache}/drupal-qa
  local key
  key=$(printf '%s' "${QA_PROJECT_ROOT:-$PWD}" | cksum | cut -d' ' -f1)
  local dir="$base/${QA_PROJECT_NAME:-project}-$key"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

# ---------------------------------------------------------------------------
# Drupal / DDEV detection
# ---------------------------------------------------------------------------

# Walk up from $1 looking for a Drupal root (a directory whose core/ holds
# Drupal.php). Handles both drupal/recommended-project (web/) and legacy layouts.
find_drupal_root() {
  local dir=$1
  dir=$(cd "$dir" 2>/dev/null && pwd) || return 1
  while [[ "$dir" != "/" && -n "$dir" ]]; do
    local candidate
    for candidate in "$dir" "$dir/web" "$dir/docroot" "$dir/html" "$dir/public"; do
      if [[ -f "$candidate/core/lib/Drupal.php" ]]; then
        printf '%s' "$candidate"; return 0
      fi
    done
    dir=$(dirname "$dir")
  done
  return 1
}

# The composer project root: the directory holding composer.json + vendor/.
find_composer_root() {
  local dir=$1
  dir=$(cd "$dir" 2>/dev/null && pwd) || return 1
  while [[ "$dir" != "/" && -n "$dir" ]]; do
    if [[ -f "$dir/composer.json" && -d "$dir/vendor" ]]; then
      printf '%s' "$dir"; return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

find_ddev_root() {
  local dir=$1
  dir=$(cd "$dir" 2>/dev/null && pwd) || return 1
  while [[ "$dir" != "/" && -n "$dir" ]]; do
    [[ -f "$dir/.ddev/config.yaml" ]] && { printf '%s' "$dir"; return 0; }
    dir=$(dirname "$dir")
  done
  return 1
}

find_git_root() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null
}

# Read the Drupal core version from the installed core, which is more reliable
# than parsing composer constraints.
detect_core_version() {
  local root=$1
  [[ -z "$root" ]] && return 1
  local f="$root/core/lib/Drupal.php"
  [[ -f "$f" ]] || return 1
  grep -oE "const VERSION = '[^']+'" "$f" 2>/dev/null | head -1 | sed -E "s/.*'([^']+)'.*/\1/"
}

# Classify a directory: module, theme, profile, recipe, core, or site.
detect_project_type() {
  local dir=$1
  [[ -f "$dir/recipe.yml" ]] && { printf 'recipe'; return 0; }
  if [[ -f "$dir/core/lib/Drupal.php" ]]; then printf 'core'; return 0; fi
  if [[ "$(basename "$dir")" == "core" && -f "$dir/lib/Drupal.php" ]]; then printf 'core'; return 0; fi

  local info name
  name=$(basename "$dir")
  info="$dir/$name.info.yml"
  if [[ ! -f "$info" ]]; then
    # Single .info.yml with a different basename still identifies the project.
    info=$(find "$dir" -maxdepth 1 -name '*.info.yml' | head -1)
  fi
  if [[ -n "$info" && -f "$info" ]]; then
    local t
    t=$(grep -E "^type:" "$info" | head -1 | sed -E 's/^type:[[:space:]]*//; s/[[:space:]]*$//' | tr -d "'\"")
    [[ -n "$t" ]] && { printf '%s' "$t"; return 0; }
    printf 'module'; return 0
  fi

  [[ -f "$dir/composer.json" ]] && { printf 'site'; return 0; }
  printf 'unknown'
}

# Find a module/theme by machine name inside the Drupal root. This is what makes
# `drupal-qa lint commerce` work from anywhere in the project.
resolve_module_path() {
  local name=$1 root=${2:-}
  [[ -z "$root" ]] && return 1
  local hit
  # Prefer custom over contrib over core: when both exist the developer almost
  # certainly means the one they can edit.
  local -a search=(
    "$root/modules/custom" "$root/themes/custom" "$root/profiles/custom"
    "$root/modules/contrib" "$root/themes/contrib" "$root/profiles/contrib"
    "$root/modules" "$root/themes" "$root/profiles"
    "$root/core/modules" "$root/core/themes" "$root/core/profiles"
    "$root/recipes"
  )
  local base
  for base in "${search[@]}"; do
    [[ -d "$base" ]] || continue
    hit=$(find "$base" -maxdepth 3 -type d -name "$name" -print -quit 2>/dev/null)
    if [[ -n "$hit" ]] && { [[ -f "$hit/$name.info.yml" ]] || [[ -f "$hit/recipe.yml" ]]; }; then
      printf '%s' "$hit"; return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Target resolution
#
# A target is a path, a module/theme machine name, or empty (meaning "whatever
# I am standing in"). Resolving all three the same way is what lets the tool be
# used without thinking about where you are.
# ---------------------------------------------------------------------------

resolve_target() {
  local arg=${1:-}
  QA_TARGET_ARG=$arg

  local start=$PWD
  if [[ -n "$arg" && -e "$arg" ]]; then
    if [[ -d "$arg" ]]; then
      QA_TARGET_PATH=$(cd "$arg" && pwd)
      start=$QA_TARGET_PATH
    else
      QA_TARGET_PATH=$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")
      QA_TARGET_FILE=$QA_TARGET_PATH
      start=$(dirname "$QA_TARGET_PATH")
    fi
  fi

  # Roots that do not depend on the target being a module.
  QA_DRUPAL_ROOT=$(find_drupal_root "${QA_CORE_OVERRIDE:-$start}" || true)
  QA_DDEV_ROOT=$(find_ddev_root "$start" || true)

  # A ddev project tells us its docroot; trust it over guessing.
  if [[ -z "$QA_DRUPAL_ROOT" && -n "$QA_DDEV_ROOT" ]]; then
    local docroot
    docroot=$(grep -E '^docroot:' "$QA_DDEV_ROOT/.ddev/config.yaml" 2>/dev/null | head -1 | sed -E 's/^docroot:[[:space:]]*//' | tr -d '"'"'"'')
    [[ -n "$docroot" && -f "$QA_DDEV_ROOT/$docroot/core/lib/Drupal.php" ]] && QA_DRUPAL_ROOT="$QA_DDEV_ROOT/$docroot"
  fi

  # Named module/theme, resolved against the Drupal root.
  if [[ -n "$arg" && -z "${QA_TARGET_PATH:-}" ]]; then
    local hit
    if hit=$(resolve_module_path "$arg" "$QA_DRUPAL_ROOT"); then
      QA_TARGET_PATH=$hit
      start=$hit
      info "Resolved '$arg' to ${hit/#$QA_DRUPAL_ROOT\//}"
    else
      die "No such path or module/theme: '$arg'. Use a path, or a machine name inside $([[ -n "$QA_DRUPAL_ROOT" ]] && echo "$QA_DRUPAL_ROOT" || echo 'a Drupal root')."
    fi
  fi

  QA_TARGET_PATH=${QA_TARGET_PATH:-$PWD}

  # The project root is the module/theme dir, walking up from the target until
  # something looks like a project. Falls back to the target itself.
  QA_PROJECT_ROOT=$(project_root_of "$QA_TARGET_PATH")
  QA_PROJECT_TYPE=$(detect_project_type "$QA_PROJECT_ROOT")
  QA_PROJECT_NAME=$(basename "$QA_PROJECT_ROOT")

  QA_GIT_ROOT=$(find_git_root "$QA_TARGET_PATH" || true)
  QA_COMPOSER_ROOT=$(find_composer_root "${QA_DRUPAL_ROOT:-$QA_TARGET_PATH}" || find_composer_root "$QA_TARGET_PATH" || true)
  if [[ -n "$QA_COMPOSER_ROOT" ]]; then
    QA_COMPOSER_BIN_DIR="$QA_COMPOSER_ROOT/vendor/bin"
    [[ -d "$QA_COMPOSER_BIN_DIR" ]] || QA_COMPOSER_BIN_DIR=""
  fi
  QA_CORE_VERSION=$(detect_core_version "$QA_DRUPAL_ROOT" || true)

  export QA_TARGET_PATH QA_PROJECT_ROOT QA_PROJECT_TYPE QA_PROJECT_NAME
  export QA_DRUPAL_ROOT QA_DDEV_ROOT QA_GIT_ROOT QA_COMPOSER_ROOT QA_COMPOSER_BIN_DIR QA_CORE_VERSION

  # Needs QA_COMPOSER_ROOT and QA_DDEV_ROOT, so it runs last.
  detect_php_version
}

project_root_of() {
  local dir=$1
  [[ -f "$dir" ]] && dir=$(dirname "$dir")
  local probe=$dir
  while [[ "$probe" != "/" && -n "$probe" ]]; do
    local name; name=$(basename "$probe")
    if [[ -f "$probe/$name.info.yml" || -f "$probe/recipe.yml" ]]; then
      printf '%s' "$probe"; return 0
    fi
    # Stop climbing at the Drupal root or a git root: beyond that we are no
    # longer inside "a project" in any useful sense.
    [[ -n "${QA_DRUPAL_ROOT:-}" && "$probe" == "$QA_DRUPAL_ROOT" ]] && break
    [[ -f "$probe/.git" || -d "$probe/.git" ]] && break
    probe=$(dirname "$probe")
  done
  printf '%s' "$dir"
}

# ---------------------------------------------------------------------------
# Changed-file selection
#
# Linting an inherited contrib module in full is demoralising: thousands of
# pre-existing warnings bury the three you just introduced. `--changed` is the
# answer, and it is why this tool gets used a second time.
# ---------------------------------------------------------------------------

changed_files() {
  local ref=${QA_CHANGED_REF:-}
  local root=${QA_GIT_ROOT:-}
  [[ -z "$root" ]] && { warn "--changed needs a git repository; linting everything instead."; return 1; }

  if [[ -z "$ref" ]]; then
    # Compare against the merge base with the upstream/default branch so that a
    # long-lived feature branch does not re-report the whole branch every time.
    local base
    for base in "@{upstream}" origin/HEAD main master 11.x 10.x; do
      if git -C "$root" rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
        ref=$(git -C "$root" merge-base HEAD "$base" 2>/dev/null) && break
      fi
    done
    ref=${ref:-HEAD}
  fi
  debug "changed files relative to $ref"

  {
    git -C "$root" diff --name-only --diff-filter=ACMR "$ref" -- "$QA_TARGET_PATH" 2>/dev/null
    git -C "$root" diff --name-only --diff-filter=ACMR --cached -- "$QA_TARGET_PATH" 2>/dev/null
    git -C "$root" ls-files --others --exclude-standard -- "$QA_TARGET_PATH" 2>/dev/null
  } | sed "s|^|$root/|" | sort -u | while read -r f; do
    [[ -f "$f" ]] && printf '%s\n' "$f"
  done
}

# Filter a newline-separated file list by extension. Usage:
#   filter_by_ext "php|module|inc" <<< "$files"
filter_by_ext() {
  grep -E "\.($1)$" || true
}

# Build the list of paths a tool should look at: either the changed files, or
# the target itself.
target_paths_for() {
  local exts=$1
  if [[ "${QA_CHANGED:-0}" == "1" ]]; then
    local files
    files=$(changed_files | filter_by_ext "$exts")
    printf '%s' "$files"
    return 0
  fi
  printf '%s' "$QA_TARGET_PATH"
}

# True when the target contains at least one file with one of these extensions.
# Mirrors the *-files-exist rules in the GitLab template so that a PHP-only
# module does not get a spurious "stylelint failed: no CSS" error.
has_files_with_ext() {
  local exts=$1
  find -L "$QA_TARGET_PATH" \
    \( -name node_modules -o -name vendor -o -name .git \) -prune -o \
    -type f -regextype posix-extended -regex ".*\.($exts)$" -print -quit 2>/dev/null | grep -q .
}
