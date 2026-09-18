#!/usr/bin/env bash
# One function per CI validate job. Each resolves its own config, decides whether
# it applies to this target at all, and records a result.
# shellcheck shell=bash

# Announce a tool and where its configuration came from. Provenance up front is
# what stops "why is it complaining about that?" from becoming a bug report.
announce() {
  local name=$1 config=${2:-}
  printf '\n%s▸ %s%s' "$C_CYAN$C_BOLD" "$name" "$C_RESET" >&2
  [[ -n "${QA_CONFIG_ORIGIN:-}" ]] && printf '%s  config: %s%s' "$C_DIM" "$QA_CONFIG_ORIGIN" "$C_RESET" >&2
  printf '\n' >&2
  [[ -n "$config" ]] && debug "config file: $config"
  return 0
}

# Turn a newline-separated path list into an array, or bail out when empty.
# shellcheck disable=SC2178
read_paths() {
  local list=$1
  QA_PATHS=()
  [[ -z "$list" ]] && return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] && QA_PATHS+=("$line")
  done <<< "$list"
  [[ ${#QA_PATHS[@]} -gt 0 ]]
}

PHP_EXTS='php|module|inc|install|theme|profile|engine|test'
JS_EXTS='js|yml|yaml'
CSS_EXTS='css'
TWIG_EXTS='twig'

# ---------------------------------------------------------------------------
# PHP syntax lint (CI: composer-lint's parallel-lint step)
# ---------------------------------------------------------------------------

tool_php_lint() {
  local bin; bin=$(php_tool parallel-lint) || { record_result php-lint skip "parallel-lint unavailable"; return 0; }
  has_files_with_ext "$PHP_EXTS" || { record_result php-lint skip "no PHP files"; return 0; }
  local list; list=$(target_paths_for "$PHP_EXTS")
  read_paths "$list" || { record_result php-lint skip "no changed PHP files"; return 0; }

  QA_CONFIG_ORIGIN=""
  announce "php-lint (syntax)"

  local status=pass
  php_run "$bin" -e "php,module,inc,install,theme,profile,engine" \
    --exclude vendor --exclude node_modules --no-progress \
    "${QA_PATHS[@]}" || status=fail
  record_result php-lint "$status"
}

# ---------------------------------------------------------------------------
# composer validate (CI: composer-lint)
# ---------------------------------------------------------------------------

tool_composer_lint() {
  [[ -f "$QA_PROJECT_ROOT/composer.json" ]] || { record_result composer skip "no composer.json"; return 0; }
  command -v composer >/dev/null 2>&1 || { record_result composer skip "composer unavailable"; return 0; }
  QA_CONFIG_ORIGIN=""
  announce "composer validate"

  # CI validates without the lock file, because a contrib module's lock is not
  # what gets installed downstream. Mirror that, without touching the user's
  # working tree.
  local status=pass args=(validate --no-interaction --ansi)
  [[ -f "$QA_PROJECT_ROOT/composer.lock" ]] && args+=(--no-check-lock)
  [[ "$QA_PROJECT_TYPE" != "site" ]] && args+=(--no-check-publish)

  ( cd "$QA_PROJECT_ROOT" && run_cmd composer "${args[@]}" ) || status=fail
  record_result composer "$status"
}

# ---------------------------------------------------------------------------
# PHPCS / PHPCBF
# ---------------------------------------------------------------------------

phpcs_common_args() {
  local config=$1
  QA_PHPCS_ARGS=(--standard="$config" --basepath="$QA_PROJECT_ROOT" -s --colors --report-width=120)
  local paths
  if paths=$(phpcs_standards_paths); then
    QA_PHPCS_ARGS+=(--runtime-set installed_paths "$paths")
  fi
  # A per-project cache makes repeat runs near-instant.
  QA_PHPCS_ARGS+=(--cache="$(cache_dir)/phpcs.cache")
  [[ -n "${QA_EXTRA_PHPCS:-}" ]] && read -ra extra <<< "$QA_EXTRA_PHPCS" && QA_PHPCS_ARGS+=("${extra[@]}")
}

tool_phpcs() {
  local bin; bin=$(php_tool phpcs) || { record_result phpcs skip "phpcs unavailable"; return 0; }
  has_files_with_ext "$PHP_EXTS|yml|txt|md" || { record_result phpcs skip "no PHP files"; return 0; }

  local list; list=$(target_paths_for "$PHP_EXTS|yml")
  read_paths "$list" || { record_result phpcs skip "no changed PHP files"; return 0; }

  local config; config=$(config_phpcs)
  announce "phpcs" "$config"

  phpcs_common_args "$config"
  case "${QA_FORMAT:-pretty}" in
    junit)  QA_PHPCS_ARGS+=(--report-junit="${QA_REPORT_DIR:-$PWD}/phpcs-junit.xml") ;;
    gitlab) QA_PHPCS_ARGS+=(--report=\\Micheh\\PhpCodeSniffer\\Report\\Gitlab --report-file="${QA_REPORT_DIR:-$PWD}/phpcs-gitlab.json") ;;
    json)   QA_PHPCS_ARGS+=(--report=json) ;;
    *)      QA_PHPCS_ARGS+=(--report-full --report-summary --report-source) ;;
  esac

  local status=pass
  php_run "$bin" "${QA_PHPCS_ARGS[@]}" "${QA_PATHS[@]}" || status=fail
  if [[ "$status" == fail ]]; then
    log ""
    log "  ${C_DIM}Most of these are auto-fixable: ${C_RESET}${C_CYAN}drupal-qa fix ${QA_TARGET_ARG:-.}${C_RESET}"
  fi
  record_result phpcs "$status"
}

tool_phpcbf() {
  local bin; bin=$(php_tool phpcbf) || { record_result phpcbf skip "phpcbf unavailable"; return 0; }
  has_files_with_ext "$PHP_EXTS|yml" || { record_result phpcbf skip "no PHP files"; return 0; }

  local list; list=$(target_paths_for "$PHP_EXTS|yml")
  read_paths "$list" || { record_result phpcbf skip "no changed PHP files"; return 0; }

  local config; config=$(config_phpcs)
  announce "phpcbf (fixing)" "$config"

  phpcs_common_args "$config"
  # phpcbf exits 1 when it fixed something and 2 on error, which is the opposite
  # of what a caller expects. Translate.
  local rc=0
  php_run "$bin" "${QA_PHPCS_ARGS[@]}" "${QA_PATHS[@]}" || rc=$?
  case $rc in
    0) record_result phpcbf pass "nothing to fix" ;;
    1) record_result phpcbf pass "fixed some files" ;;
    *) record_result phpcbf fail "exit $rc" ;;
  esac
}

# ---------------------------------------------------------------------------
# PHPStan
# ---------------------------------------------------------------------------

tool_phpstan() {
  local bin; bin=$(php_tool phpstan) || { record_result phpstan skip "phpstan unavailable"; return 0; }
  has_files_with_ext "$PHP_EXTS" || { record_result phpstan skip "no PHP files"; return 0; }

  local list; list=$(target_paths_for "$PHP_EXTS")
  read_paths "$list" || { record_result phpstan skip "no changed PHP files"; return 0; }

  local config; config=$(config_phpstan)
  announce "phpstan" "$config"

  if [[ -z "${QA_DRUPAL_ROOT:-}" ]]; then
    warn "No Drupal root found. PHPStan will run without Drupal's autoloader, so"
    warn "expect 'class not found' noise. Point at a site with --core=<path>, or"
    warn "run this from inside a Drupal codebase."
  fi

  local -a args=(analyse --configuration="$config" --no-progress)
  [[ -n "${QA_PHPSTAN_LEVEL:-}" ]] && args+=(--level="$QA_PHPSTAN_LEVEL")
  # Drupal's own autoloader is what makes phpstan-drupal useful; without it every
  # service and entity class is unknown.
  if [[ -n "${QA_COMPOSER_ROOT:-}" && -f "$QA_COMPOSER_ROOT/vendor/autoload.php" ]]; then
    args+=(--autoload-file="$QA_COMPOSER_ROOT/vendor/autoload.php")
  fi
  case "${QA_FORMAT:-pretty}" in
    junit)  args+=(--error-format=junit) ;;
    gitlab) args+=(--error-format=gitlab) ;;
    json)   args+=(--error-format=json) ;;
  esac
  [[ -n "${QA_EXTRA_PHPSTAN:-}" ]] && read -ra extra <<< "$QA_EXTRA_PHPSTAN" && args+=("${extra[@]}")

  local status=pass
  php_run "$bin" "${args[@]}" "${QA_PATHS[@]}" || status=fail
  if [[ "$status" == fail ]]; then
    log ""
    log "  ${C_DIM}To accept the current state and only fail on new problems:${C_RESET} ${C_CYAN}drupal-qa baseline ${QA_TARGET_ARG:-.}${C_RESET}"
  fi
  record_result phpstan "$status"
}

# ---------------------------------------------------------------------------
# CSpell
# ---------------------------------------------------------------------------

tool_cspell() {
  local bin; bin=$(node_tool cspell) || { record_result cspell skip "cspell unavailable"; return 0; }

  local -a globs
  if [[ "${QA_CHANGED:-0}" == "1" ]]; then
    local list; list=$(changed_files)
    read_paths "$list" || { record_result cspell skip "no changed files"; return 0; }
    globs=("${QA_PATHS[@]}")
  else
    globs=("$QA_TARGET_PATH/**")
  fi

  local config; config=$(config_cspell)
  announce "cspell" "$config"

  # --no-config-search is essential, not tidiness. Without it CSpell keeps
  # walking up from each file and merging any .cspell.json it finds, so a
  # contrib module checked out inside a site inherits that site's ignorePaths.
  # A site that excludes web/modules/contrib from its own spell check — a
  # perfectly reasonable thing to do — then silently causes every file in the
  # module to be skipped, and the job reports success having checked nothing.
  local -a args=(-c "$config" --no-config-search --show-suggestions --show-context
                 --no-progress --cache --cache-location "$(cache_dir)/cspell.cache")
  [[ "${QA_VERBOSE:-0}" == "1" ]] || args+=(--no-must-find-files)
  [[ -n "${QA_EXTRA_CSPELL:-}" ]] && read -ra extra <<< "$QA_EXTRA_CSPELL" && args+=("${extra[@]}")

  # Capture the output so the summary line can be inspected: "checked 0 files"
  # is a far more dangerous result than "found 3 typos", because it looks
  # exactly like success.
  local out; out=$(mktemp)
  local status=pass
  ( cd "$QA_PROJECT_ROOT" && run_cmd "$bin" "${args[@]}" "${globs[@]}" ) > >(tee "$out" >&2) 2>&1 || status=fail
  wait

  if [[ "$status" == fail ]]; then
    log ""
    log "  ${C_DIM}Real jargon rather than a typo? Add it:${C_RESET} ${C_CYAN}drupal-qa cspell ${QA_TARGET_ARG:-.} --accept-words${C_RESET}"
    record_result cspell fail
  elif grep -qE 'Files checked: 0\b' "$out" && grep -qE 'skipped: [1-9]' "$out"; then
    local skipped
    skipped=$(grep -oE 'skipped: [0-9]+' "$out" | head -1 | grep -oE '[0-9]+')
    warn "CSpell checked no files: all $skipped were excluded by its configuration."
    warn "Check the ignorePaths in $config."
    record_result cspell warn "0 checked, $skipped skipped"
  else
    record_result cspell pass
  fi
  rm -f "$out"
}

# Append every unrecognised word to the project dictionary. This is the same
# artifact the CI job produces, but written straight into the repo where it
# belongs.
cspell_accept_words() {
  local bin; bin=$(node_tool cspell) || die "cspell unavailable"
  local config; config=$(config_cspell)
  local words="$QA_PROJECT_ROOT/.cspell-project-words.txt"
  local tmp; tmp=$(mktemp)

  ( cd "$QA_PROJECT_ROOT" && "$bin" -c "$config" --words-only --unique --no-progress "$QA_TARGET_PATH/**" ) \
    2>/dev/null | tr '[:upper:]' '[:lower:]' > "$tmp" || true

  if [[ ! -s "$tmp" ]]; then
    info "No unrecognised words to add."
    rm -f "$tmp"
    return 0
  fi

  # Keep any leading comment block where the author put it; sorting the whole
  # file would shuffle the explanation into the middle of the word list.
  local header="" body=""
  if [[ -f "$words" ]]; then
    header=$(sed -n '/^[^#]/q;p' "$words")
    body=$(grep -v '^#' "$words" | grep -v '^[[:space:]]*$' || true)
  fi

  local before=0
  [[ -n "$body" ]] && before=$(wc -l <<< "$body")

  {
    [[ -n "$header" ]] && printf '%s\n' "$header"
    { [[ -n "$body" ]] && printf '%s\n' "$body"; cat "$tmp"; } | LC_ALL=C sort -u
  } > "$words.new"
  mv "$words.new" "$words"
  rm -f "$tmp"

  local after; after=$(grep -cv '^#' "$words")
  info "Added $((after - before)) word(s) to ${words/#$QA_PROJECT_ROOT\//}. Review it before committing."
}

# ---------------------------------------------------------------------------
# ESLint
# ---------------------------------------------------------------------------

tool_eslint() {
  has_files_with_ext "$JS_EXTS" || { record_result eslint skip "no JS/YAML files"; return 0; }

  local list; list=$(target_paths_for "$JS_EXTS")
  read_paths "$list" || { record_result eslint skip "no changed JS/YAML files"; return 0; }

  # config_eslint picks the binary too: ESLint 8 and 9 read different config
  # formats and accept different flags, so they cannot be chosen independently.
  # It must be called with stdout redirected rather than in $(...), or the
  # variables it sets would be trapped in the subshell and the v8 flags would be
  # used against a v9 binary.
  QA_CONFIG_FILE=""
  config_eslint > /dev/null
  local config=$QA_CONFIG_FILE
  local bin=${QA_ESLINT_BIN:-}
  [[ -n "$bin" ]] || bin=$(node_tool eslint) || { record_result eslint skip "eslint unavailable"; return 0; }

  announce "eslint" "$config"

  local -a args=(--no-error-on-unmatched-pattern)
  args+=(--config "$config")
  args+=(--cache --cache-location "$(cache_dir)/eslint.cache")

  if [[ "${QA_ESLINT_FLAT:-0}" == "1" ]]; then
    # Flat config declares its own file patterns and resolves its own plugins;
    # --ext, --resolve-plugins-relative-to and --no-eslintrc were all removed.
    :
  else
    # shellcheck disable=SC2054  # --ext takes a comma-separated list; one argument.
    args+=(--ignore-pattern='*.es6.js' --ext=.js,.yml)
    [[ -n "${QA_ESLINT_BASE:-}" ]] && args+=(--resolve-plugins-relative-to "$QA_ESLINT_BASE")
    # --config does not switch off the cascade. Linting core/modules/node would
    # otherwise also pick up core/.eslintrc.json, whose `extends: airbnb-base`
    # cannot resolve unless core's node_modules is installed, so the run dies on
    # a config error instead of reporting anything.
    [[ "$QA_CONFIG_ORIGIN" != project* ]] && args+=(--no-eslintrc)
  fi

  [[ "${QA_FIX:-0}" == "1" ]] && args+=(--fix)
  case "${QA_FORMAT:-pretty}" in
    junit)  args+=(--format=junit --output-file="${QA_REPORT_DIR:-$PWD}/eslint-junit.xml") ;;
    json)   args+=(--format=json) ;;
  esac
  [[ -n "${QA_EXTRA_ESLINT:-}" ]] && read -ra extra <<< "$QA_EXTRA_ESLINT" && args+=("${extra[@]}")

  local status=pass
  ( cd "$QA_PROJECT_ROOT" && run_cmd "$bin" "${args[@]}" "${QA_PATHS[@]}" ) || status=fail
  record_result eslint "$status"
}

# ---------------------------------------------------------------------------
# Stylelint
# ---------------------------------------------------------------------------

tool_stylelint() {
  local bin; bin=$(node_tool stylelint) || { record_result stylelint skip "stylelint unavailable"; return 0; }
  has_files_with_ext "$CSS_EXTS" || { record_result stylelint skip "no CSS files"; return 0; }

  local -a globs
  if [[ "${QA_CHANGED:-0}" == "1" ]]; then
    local list; list=$(target_paths_for "$CSS_EXTS")
    read_paths "$list" || { record_result stylelint skip "no changed CSS files"; return 0; }
    globs=("${QA_PATHS[@]}")
  else
    globs=("$QA_TARGET_PATH/**/*.css")
  fi

  local config; config=$(config_stylelint)
  announce "stylelint" "$config"

  local -a args=(--formatter verbose --color --allow-empty-input)
  args+=(--config "$config")
  # `extends` entries resolve relative to --config-basedir. The overlay sits in
  # the cache directory, which has no node_modules of its own, so point this at
  # whichever tree the real config came from.
  args+=(--config-basedir "$(node_modules_root || dirname "$config")")
  args+=(--cache --cache-location "$(cache_dir)/stylelint.cache")
  [[ -f "$QA_PROJECT_ROOT/.stylelintignore" ]] && args+=(--ignore-path "$QA_PROJECT_ROOT/.stylelintignore")
  [[ "${QA_FIX:-0}" == "1" ]] && args+=(--fix)
  [[ -n "${QA_EXTRA_STYLELINT:-}" ]] && read -ra extra <<< "$QA_EXTRA_STYLELINT" && args+=("${extra[@]}")

  local status=pass
  ( cd "$QA_PROJECT_ROOT" && run_cmd "$bin" "${args[@]}" "${globs[@]}" ) || status=fail
  record_result stylelint "$status"
}

# ---------------------------------------------------------------------------
# Prettier (fix-only; core runs it through the ESLint and Stylelint plugins)
# ---------------------------------------------------------------------------

tool_prettier() {
  local bin; bin=$(node_tool prettier) || { record_result prettier skip "prettier unavailable"; return 0; }
  has_files_with_ext "js|css" || { record_result prettier skip "no JS/CSS files"; return 0; }

  local -a globs
  if [[ "${QA_CHANGED:-0}" == "1" ]]; then
    local list; list=$(target_paths_for "js|css")
    read_paths "$list" || { record_result prettier skip "no changed JS/CSS files"; return 0; }
    globs=("${QA_PATHS[@]}")
  else
    globs=("$QA_TARGET_PATH/**/*.{js,css}")
  fi

  local config; config=$(config_prettier)
  announce "prettier" "$config"

  local -a args=(--config "$config" --ignore-unknown --no-error-on-unmatched-pattern)
  if [[ "${QA_FIX:-0}" == "1" ]]; then args+=(--write); else args+=(--check); fi

  local status=pass
  ( cd "$QA_PROJECT_ROOT" && run_cmd "$bin" "${args[@]}" "${globs[@]}" ) || status=fail
  record_result prettier "$status"
}

# ---------------------------------------------------------------------------
# Twig CS Fixer
# ---------------------------------------------------------------------------

tool_twig() {
  local bin; bin=$(php_tool twig-cs-fixer) || { record_result twig skip "twig-cs-fixer unavailable"; return 0; }
  has_files_with_ext "$TWIG_EXTS" || { record_result twig skip "no Twig files"; return 0; }

  local list; list=$(target_paths_for "$TWIG_EXTS")
  read_paths "$list" || { record_result twig skip "no changed Twig files"; return 0; }

  local config; config=$(config_twig)
  announce "twig-cs-fixer" "$config"

  local -a args=(lint -c "$config")
  [[ "${QA_FIX:-0}" == "1" ]] && args+=(--fix)
  [[ "${QA_FORMAT:-pretty}" == "gitlab" ]] && args+=(--report=gitlab)
  [[ -n "${QA_EXTRA_TWIG:-}" ]] && read -ra extra <<< "$QA_EXTRA_TWIG" && args+=("${extra[@]}")

  # {% trans %} needs Drupal's token parser, which needs Drupal on the
  # autoloader. Supply it when we know where it is.
  local -a php_args=()
  if [[ -n "${QA_COMPOSER_ROOT:-}" && -f "$QA_COMPOSER_ROOT/vendor/autoload.php" ]]; then
    php_args+=(-d "auto_prepend_file=$QA_COMPOSER_ROOT/vendor/autoload.php")
  fi

  # Twig CS Fixer's cache location is set *inside* the config file, and core's
  # hard-codes the relative path './core/.twigcsfixercache'. Run from the cache
  # directory so a relative path like that lands there instead of creating a
  # stray core/ directory inside whatever module is being linted. The paths
  # passed in are absolute, so the working directory is otherwise irrelevant.
  local twig_cwd; twig_cwd=$(cache_dir)/twig
  mkdir -p "$twig_cwd/core"

  local status=pass
  ( cd "$twig_cwd" \
      && DRUPAL_QA_TWIG_CACHE="$twig_cwd/twig-cs-fixer.cache" \
         php_run "${php_args[@]}" "$bin" "${args[@]}" "${QA_PATHS[@]}" ) || status=fail
  record_result twig "$status"
}
