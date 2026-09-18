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
  local status=pass
  local -a args=(validate --no-interaction "$(color_args --ansi --no-ansi)")
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
  QA_PHPCS_ARGS=(--standard="$config" --basepath="$QA_PROJECT_ROOT" -s --report-width=120)
  QA_PHPCS_ARGS+=("$(color_args --colors --no-colors)")
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

  resolve_config config_phpcs
  local config=$QA_CONFIG_FILE
  announce "phpcs" "$config"

  phpcs_common_args "$config"
  case "${QA_FORMAT:-pretty}" in
    junit)  QA_PHPCS_ARGS+=(--report-junit="${QA_REPORT_DIR:-$PWD}/phpcs-junit.xml") ;;
    gitlab) QA_PHPCS_ARGS+=(--report=\\Micheh\\PhpCodeSniffer\\Report\\Gitlab --report-file="${QA_REPORT_DIR:-$PWD}/phpcs-gitlab.json") ;;
    json)   QA_PHPCS_ARGS+=(--report=json) ;;
    *)      QA_PHPCS_ARGS+=(--report-full --report-summary --report-source) ;;
  esac

  # Capture the report so the error/warning split can be shown. PHPCS exits
  # non-zero for warnings alone, and whether a run has errors or only warnings
  # is what decides if it blocks anything: Drupal's CI marks the phpcs job
  # allow_failure by default, so warnings are reported without stopping the
  # pipeline — but a project that sets _PHPCS_ALLOW_FAILURE: '0' makes a single
  # warning blocking.
  local out; out=$(mktemp)
  local status=pass
  php_run "$bin" "${QA_PHPCS_ARGS[@]}" "${QA_PATHS[@]}" > >(tee "$out" >&2) 2>&1 || status=fail
  wait

  local counts errors warnings note=""
  counts=$(sed -r 's/\x1B\[[0-9;]*[mK]//g' "$out" \
    | grep -oE 'A TOTAL OF [0-9]+ ERRORS? AND [0-9]+ WARNINGS?' | head -1)
  if [[ -n "$counts" ]]; then
    errors=$(grep -oE '[0-9]+' <<< "$counts" | head -1)
    warnings=$(grep -oE '[0-9]+' <<< "$counts" | tail -1)
    note="$errors error(s), $warnings warning(s)"
  fi
  rm -f "$out"

  if [[ "$status" == fail ]]; then
    log ""
    if [[ "${errors:-1}" == "0" ]]; then
      log "  ${C_DIM}Warnings only. Drupal's CI runs the phpcs job with allow_failure by default,${C_RESET}"
      log "  ${C_DIM}so these are reported but do not block the pipeline unless the project sets${C_RESET}"
      log "  ${C_DIM}_PHPCS_ALLOW_FAILURE: '0'. Check with:${C_RESET} ${C_CYAN}drupal-qa ci --list${C_RESET}"
    else
      log "  ${C_DIM}Most of these are auto-fixable: ${C_RESET}${C_CYAN}drupal-qa fix ${QA_TARGET_ARG:-.}${C_RESET}"
    fi
  fi
  record_result phpcs "$status" "$note"
}

tool_phpcbf() {
  local bin; bin=$(php_tool phpcbf) || { record_result phpcbf skip "phpcbf unavailable"; return 0; }
  has_files_with_ext "$PHP_EXTS|yml" || { record_result phpcbf skip "no PHP files"; return 0; }

  local list; list=$(target_paths_for "$PHP_EXTS|yml")
  read_paths "$list" || { record_result phpcbf skip "no changed PHP files"; return 0; }

  resolve_config config_phpcs
  local config=$QA_CONFIG_FILE
  announce "phpcbf (fixing)" "$config"

  phpcs_common_args "$config"

  # Capture the report so the REMAINING column can be read back. "phpcbf did not
  # fix it" is nearly always PHPCS declining to: only messages it marks [x] are
  # auto-fixable, and rewrapping a long line or removing a dpm() call needs a
  # person. Saying so here saves the investigation.
  local out; out=$(mktemp)
  local rc=0
  php_run "$bin" "${QA_PHPCS_ARGS[@]}" "${QA_PATHS[@]}" > >(tee "$out" >&2) 2>&1 || rc=$?
  wait

  local fixed remaining
  fixed=$(grep -oE 'A TOTAL OF [0-9]+ ERRORS? WERE FIXED' "$out" | grep -oE '[0-9]+' | head -1)
  # Per-file rows end in two numbers: fixed, then remaining.
  remaining=$(sed -r 's/\x1B\[[0-9;]*[mK]//g' "$out" \
    | grep -oE '[0-9]+[[:space:]]+[0-9]+[[:space:]]*$' \
    | awk '{ total += $2 } END { print total + 0 }')
  rm -f "$out"

  # phpcbf exits 1 when it fixed something and 2 on error, which is the opposite
  # of what a caller expects. Translate.
  local note=""
  [[ -n "$fixed" && "$fixed" != "0" ]] && note="fixed $fixed"
  if [[ -n "$remaining" && "$remaining" != "0" ]]; then
    note="${note:+$note, }$remaining not auto-fixable"
    log ""
    log "  ${C_DIM}$remaining issue(s) cannot be fixed automatically — PHPCS only fixes what it marks${C_RESET}"
    log "  ${C_DIM}[x] in its report. Line length, discouraged functions and missing descriptions${C_RESET}"
    log "  ${C_DIM}need a person. See them with:${C_RESET} ${C_CYAN}drupal-qa phpcs ${QA_TARGET_ARG:-.}${C_RESET}"
  fi

  case $rc in
    0) record_result phpcbf pass "${note:-nothing to fix}" ;;
    1) record_result phpcbf pass "${note:-fixed some files}" ;;
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

  resolve_config config_phpstan
  local config=$QA_CONFIG_FILE
  announce "phpstan" "$config"

  if [[ -z "${QA_DRUPAL_ROOT:-}" ]]; then
    warn "No Drupal root found. PHPStan will run without Drupal's autoloader, so"
    warn "expect 'class not found' noise. Point at a site with --core=<path>, or"
    warn "run this from inside a Drupal codebase."
  fi

  local -a args=(analyse --configuration="$config" --no-progress)
  args+=("$(color_args --ansi --no-ansi)")
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

  resolve_config config_cspell
  local config=$QA_CONFIG_FILE
  announce "cspell" "$config"

  # --no-config-search is essential, not tidiness. Without it CSpell keeps
  # walking up from each file and merging any .cspell.json it finds, so a
  # contrib module checked out inside a site inherits that site's ignorePaths.
  # A site that excludes web/modules/contrib from its own spell check — a
  # perfectly reasonable thing to do — then silently causes every file in the
  # module to be skipped, and the job reports success having checked nothing.
  local -a args=(-c "$config" --no-config-search --show-suggestions --show-context
                 --no-progress --cache --cache-location "$(cache_dir)/cspell.cache")
  args+=("$(color_args --color --no-color)")
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
# Where the project keeps its accepted words.
#
# Drupal's CI templates default to .cspell-project-words.txt and let a project
# override it with the _CSPELL_DICTIONARY variable, so a project may legitimately
# use another name. Honour an explicit --dictionary, then any .txt dictionary the
# project's own CSpell config declares, then the Drupal default.
cspell_dictionary_path() {
  if [[ -n "${QA_CSPELL_DICTIONARY:-}" ]]; then
    case "$QA_CSPELL_DICTIONARY" in
      /*) printf '%s' "$QA_CSPELL_DICTIONARY" ;;
      *)  printf '%s/%s' "$QA_PROJECT_ROOT" "$QA_CSPELL_DICTIONARY" ;;
    esac
    return 0
  fi

  local cfg declared
  for cfg in "$QA_PROJECT_ROOT/.cspell.json" "$QA_PROJECT_ROOT/cspell.json" "$QA_PROJECT_ROOT/cspell.config.json"; do
    [[ -f "$cfg" ]] || continue
    declared=$(jq -r '[.dictionaryDefinitions[]? | select(.path | test("\\.txt$")) | .path] | first // empty' "$cfg" 2>/dev/null)
    if [[ -n "$declared" ]]; then
      # Declared paths are relative to the config file.
      case "$declared" in
        /*) printf '%s' "$declared" ;;
        *)  printf '%s/%s' "$QA_PROJECT_ROOT" "${declared#./}" ;;
      esac
      return 0
    fi
  done

  printf '%s/.cspell-project-words.txt' "$QA_PROJECT_ROOT"
}

# Collect the words CSpell does not recognise, lower-cased and deduplicated.
cspell_unknown_words() {
  local bin=$1 config=$2
  shift 2
  ( cd "$QA_PROJECT_ROOT" \
      && "$bin" -c "$config" --no-config-search --words-only --unique --no-progress "$@" ) \
    2>/dev/null | tr '[:upper:]' '[:lower:]' | LC_ALL=C sort -u
}

# Add every unrecognised word to the project dictionary.
#
# This is the same list the CI job publishes as _cspell_updated_project_words.txt,
# written straight into the repository where it belongs. It is deliberately a
# separate command rather than part of `drupal-qa fix`: accepting a word is
# asserting that it is not a typo, and a fixer that silently blesses "recieve"
# is worse than no spell check at all. --dry-run shows the list first.
cspell_accept_words() {
  local bin; bin=$(node_tool cspell) || die "cspell unavailable"
  resolve_config config_cspell
  local config=$QA_CONFIG_FILE
  local words; words=$(cspell_dictionary_path)

  local -a globs
  if [[ "${QA_CHANGED:-0}" == "1" ]]; then
    local list; list=$(changed_files)
    if ! read_paths "$list"; then
      info "No changed files to check."
      return 0
    fi
    globs=("${QA_PATHS[@]}")
  else
    globs=("$QA_TARGET_PATH/**")
  fi

  local new_words; new_words=$(cspell_unknown_words "$bin" "$config" "${globs[@]}")
  if [[ -z "$new_words" ]]; then
    info "No unrecognised words to add."
    return 0
  fi

  # Only report words that are not already accepted, so the count means
  # something on a second run.
  local existing="" added
  if [[ -f "$words" ]]; then
    existing=$(grep -v '^[[:space:]]*#' "$words" | grep -v '^[[:space:]]*$' | tr '[:upper:]' '[:lower:]' | LC_ALL=C sort -u)
  fi
  added=$(LC_ALL=C comm -23 <(printf '%s\n' "$new_words") <(printf '%s\n' "$existing"))

  if [[ -z "$added" ]]; then
    info "Nothing new: all $(wc -l <<< "$new_words") reported word(s) are already in ${words/#$QA_PROJECT_ROOT\//}."
    return 0
  fi

  printf '\n%sWords to accept%s (%d)\n' "$C_BOLD" "$C_RESET" "$(wc -l <<< "$added")" >&2
  # One word per line, indented; the list is newline-separated already.
  local word
  while IFS= read -r word; do
    printf '  %s\n' "$word" >&2
  done <<< "$added"
  printf '\n' >&2

  if [[ "${QA_DRY_RUN:-0}" == "1" ]]; then
    info "Dry run. Add them with: drupal-qa cspell ${QA_TARGET_ARG:-.} --accept-words"
    return 0
  fi

  # Preserve any leading comment block; sorting the whole file would shuffle the
  # explanation into the middle of the word list.
  local header=""
  if [[ -f "$words" ]]; then
    header=$(sed -n '/^[^#]/q;p' "$words")
  else
    header="# Words that are correct in this project but not in any standard dictionary.
# One per line, lower case. Add more with: drupal-qa cspell --accept-words"
  fi

  {
    [[ -n "$header" ]] && printf '%s\n' "$header"
    { [[ -n "$existing" ]] && printf '%s\n' "$existing"; printf '%s\n' "$added"; } | LC_ALL=C sort -u
  } > "$words.new"
  mv "$words.new" "$words"

  info "Added $(wc -l <<< "$added") word(s) to ${words/#$QA_PROJECT_ROOT\//}. Review it before committing."

  # Verify the dictionary is actually loaded. A project whose own .cspell.json
  # does not declare this file will keep reporting the same words for ever, and
  # silently writing to a file nothing reads is the most confusing possible
  # outcome.
  #
  # Re-resolve the config first: the generated overlay only wires in the
  # dictionary when the file exists, and a moment ago it did not.
  resolve_config config_cspell
  local recheck_config=$QA_CONFIG_FILE
  local still; still=$(cspell_unknown_words "$bin" "$recheck_config" "${globs[@]}")
  [[ -z "$still" ]] && return 0

  warn "CSpell still reports $(wc -l <<< "$still") word(s) after the update."
  if [[ "$QA_CONFIG_ORIGIN" == project* ]]; then
    warn "This project's own CSpell config does not load ${words##*/}. Add to $recheck_config:"
    log '    "dictionaryDefinitions": [{ "name": "project-words", "path": "./'"${words##*/}"'", "addWords": true }],'
    log '    "dictionaries": ["project-words"]'
  else
    warn "Those words may contain characters CSpell splits differently; check them by hand."
  fi
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
  resolve_config config_eslint
  local config=$QA_CONFIG_FILE
  local bin=${QA_ESLINT_BIN:-}
  [[ -n "$bin" ]] || bin=$(node_tool eslint) || { record_result eslint skip "eslint unavailable"; return 0; }

  announce "eslint" "$config"

  local -a args=(--no-error-on-unmatched-pattern)
  args+=("$(color_args --color --no-color)")
  args+=(--config "$config")
  args+=(--cache --cache-location "$(cache_dir)/eslint.cache")

  if [[ "${QA_ESLINT_FLAT:-0}" == "1" ]]; then
    # Flat config declares its own file patterns and resolves its own plugins;
    # --ext, --resolve-plugins-relative-to and --no-eslintrc were all removed.
    :
  else
    # shellcheck disable=SC2054  # --ext takes a comma-separated list; one argument.
    args+=(--ignore-pattern='*.es6.js' --ext=.js,.yml)
    # Flat config carries its own ignores; only eslintrc needs this.
    local ignore_file
    ignore_file=$(find_ignore_file .eslintignore) && args+=(--ignore-path "$ignore_file")
    [[ -n "${QA_ESLINT_BASE:-}" ]] && args+=(--resolve-plugins-relative-to "$QA_ESLINT_BASE")
    # --config does not switch off the cascade, and the cascade is never what we
    # want here. Drupal scaffolds web/.eslintrc.json into every site, extending
    # core/.eslintrc.json — so linting any module would also pull that in, and
    # its `extends: airbnb-base` cannot resolve unless core's node_modules is
    # installed. The overlay already layers core and the project explicitly, so
    # nothing is lost by taking the cascade out of the picture.
    args+=(--no-eslintrc)
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

  resolve_config config_stylelint
  local config=$QA_CONFIG_FILE
  announce "stylelint" "$config"

  local -a args=(--formatter verbose --allow-empty-input)
  args+=("$(color_args --color --no-color)")
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

  resolve_config config_prettier
  local config=$QA_CONFIG_FILE
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

  resolve_config config_twig
  local config=$QA_CONFIG_FILE
  announce "twig-cs-fixer" "$config"

  local -a args=(lint -c "$config" "$(color_args --ansi --no-ansi)")
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
