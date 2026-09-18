#!/usr/bin/env bash
# Tool configuration resolution.
#
# The precedence is the same one Drupal's GitLab CI templates use, because the
# whole point is that a green local run predicts a green pipeline:
#
#   1. The project's own config file, if it has one.
#   2. For ESLint / Stylelint / Prettier / Twig CS Fixer: the file shipped in the
#      detected Drupal core. (This is what the CI jobs link to.)
#   3. For PHPCS / PHPStan / CSpell: the contrib default from the CI templates,
#      bundled here so no network round-trip is needed. (CI curls these from
#      gitlab_templates/assets; core's own stricter configs are opt-in via
#      --config-source=core.)
#
# `drupal-qa info` prints the decision for every tool, so this is never a guess.
# shellcheck shell=bash

# Echo the first existing path from the arguments.
first_existing() {
  local p
  for p in "$@"; do
    [[ -n "$p" && -f "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

project_config() {
  [[ "${QA_CONFIG_SOURCE:-auto}" == "bundled" || "${QA_CONFIG_SOURCE:-auto}" == "core" ]] && return 1
  local name
  for name in "$@"; do
    [[ -f "$QA_PROJECT_ROOT/$name" ]] && { printf '%s' "$QA_PROJECT_ROOT/$name"; return 0; }
  done
  return 1
}

core_config() {
  [[ "${QA_CONFIG_SOURCE:-auto}" == "bundled" ]] && return 1
  [[ -z "${QA_DRUPAL_ROOT:-}" ]] && return 1
  local name
  for name in "$@"; do
    [[ -f "$QA_DRUPAL_ROOT/$name" ]] && { printf '%s' "$QA_DRUPAL_ROOT/$name"; return 0; }
  done
  return 1
}

assets_dir() {
  printf '%s' "${DRUPAL_QA_ASSETS:-$QA_SELF_DIR/../assets}"
}

# Records where each tool's config came from, for `drupal-qa info` and for the
# one-line provenance note printed before each tool runs.
QA_CONFIG_ORIGIN=""
QA_CONFIG_FILE=""
set_origin() { QA_CONFIG_ORIGIN=$1; }

# Config lookups are normally used as `c=$(config_phpcs)`, which runs them in a
# subshell where QA_CONFIG_ORIGIN cannot escape. Callers that need the
# provenance (drupal-qa info) instead call them with stdout redirected, which
# does run in the current shell, and read both globals afterwards.
emit_config() {
  QA_CONFIG_FILE=$1
  printf '%s' "$1"
}

# ---------------------------------------------------------------------------
# PHPCS
# ---------------------------------------------------------------------------

config_phpcs() {
  local c
  if c=$(project_config phpcs.xml phpcs.xml.dist .phpcs.xml .phpcs.xml.dist); then
    set_origin "project ($(basename "$c"))"; emit_config "$c"; return 0
  fi
  if [[ "${QA_CONFIG_SOURCE:-auto}" == "core" ]] && c=$(core_config core/phpcs.xml.dist phpcs.xml.dist); then
    set_origin "Drupal core"; emit_config "$c"; return 0
  fi
  set_origin "bundled CI default"
  emit_config "$(assets_dir)/phpcs.xml.dist"
}

# PHPCS needs installed_paths pointing at drupal/coder for the Drupal and
# DrupalPractice standards to exist at all. The composer plugin writes this into
# the toolbox vendor dir at build time, but a project-local phpcs may not have
# it, so compute it explicitly and pass it on the command line.
phpcs_standards_paths() {
  local vendor bin
  bin=$(php_tool phpcs) || return 1
  # vendor/bin/phpcs -> vendor/
  vendor=$(cd "$(dirname "$bin")/.." && pwd)
  local -a paths=()
  [[ -d "$vendor/drupal/coder/coder_sniffer" ]] && paths+=("$vendor/drupal/coder/coder_sniffer")
  [[ -d "$vendor/sirbrillig/phpcs-variable-analysis" ]] && paths+=("$vendor/sirbrillig/phpcs-variable-analysis")
  [[ -d "$vendor/slevomat/coding-standard" ]] && paths+=("$vendor/slevomat/coding-standard")
  [[ -d "$vendor/micheh/phpcs-gitlab" ]] && paths+=("$vendor/micheh/phpcs-gitlab")
  [[ ${#paths[@]} -eq 0 ]] && return 1
  local IFS=,
  printf '%s' "${paths[*]}"
}

# ---------------------------------------------------------------------------
# PHPStan
#
# Generates an overlay that includes whichever base config won, then adds the
# things PHPStan cannot work out for itself: where Drupal is, where the baseline
# lives, and a writable tmpDir (the Nix store is not).
# ---------------------------------------------------------------------------

config_phpstan() {
  local base cache overlay
  cache=$(cache_dir)
  overlay="$cache/phpstan.neon"

  if base=$(project_config phpstan.neon phpstan.neon.dist phpstan.dist.neon); then
    set_origin "project ($(basename "$base"))"
  elif [[ "${QA_CONFIG_SOURCE:-auto}" == "core" ]] && base=$(core_config core/phpstan.neon.dist) \
       && [[ -d "$QA_DRUPAL_ROOT/composer/Generator" || -d "$QA_DRUPAL_ROOT/../composer/Generator" ]]; then
    # Core's PHPStan config analyses core *from a drupal/drupal checkout*: its
    # paths and ignoreErrors entries are relative to core/ and reach ../composer,
    # which only exists in that layout. A drupal/recommended-project install has
    # no such directory and PHPStan refuses to start, so require the layout
    # rather than failing with a wall of "is neither a directory" errors.
    #
    # Both spellings are checked because the docroot may be the repository root
    # (a drupal/drupal checkout, composer/ alongside core/) or a subdirectory
    # such as web/ (composer/ one level up).
    set_origin "Drupal core"
  else
    if [[ "${QA_CONFIG_SOURCE:-auto}" == "core" ]]; then
      warn "Core's phpstan.neon.dist needs a drupal/drupal checkout (it references ../composer)."
      warn "Falling back to the contrib default. Analyse core from its own checkout to use it."
    fi
    base="$(assets_dir)/phpstan.neon"
    set_origin "bundled CI default"
  fi

  {
    printf '# Generated by drupal-qa. Edit %s instead.\n' "$base"
    printf 'includes:\n'
    printf '    - %s\n' "$base"
    # Include the project baseline if it has one, unless the base config already
    # pulls it in (a project config that references its own baseline).
    if [[ -f "$QA_PROJECT_ROOT/phpstan-baseline.neon" ]] && ! grep -q 'phpstan-baseline' "$base" 2>/dev/null; then
      printf '    - %s\n' "$QA_PROJECT_ROOT/phpstan-baseline.neon"
    fi
    printf '\nparameters:\n'
    printf '    tmpDir: %s\n' "$cache/phpstan"
    if [[ -n "${QA_PHPSTAN_LEVEL:-}" ]]; then
      printf '    level: %s\n' "$QA_PHPSTAN_LEVEL"
    fi
    # phpstan-drupal discovers the Drupal root itself and deprecates the
    # drupal_root parameter for doing so — but that discovery starts from its own
    # installation, so it only works when PHPStan lives in the site's vendor
    # directory. Running the pinned toolbox copy from the Nix store, or analysing
    # a module checked out somewhere else entirely, leaves it unable to find
    # Drupal at all: every core class is then "not found" and the report is a
    # hundred lines of noise that looks like real findings.
    #
    # So: name the root explicitly unless PHPStan is the project's own copy.
    local phpstan_bin phpstan_in_project=0
    if phpstan_bin=$(php_tool phpstan 2>/dev/null) \
       && [[ -n "${QA_COMPOSER_ROOT:-}" && "$phpstan_bin" == "$QA_COMPOSER_ROOT"/* ]]; then
      phpstan_in_project=1
    fi
    if [[ -n "${QA_DRUPAL_ROOT:-}" ]] \
       && { [[ $phpstan_in_project -eq 0 ]] || [[ "$QA_PROJECT_ROOT" != "$QA_DRUPAL_ROOT"/* ]]; }; then
      printf '    drupal:\n'
      printf '        drupal_root: %s\n' "$QA_DRUPAL_ROOT"
    fi
  } > "$overlay"

  emit_config "$overlay"
}

# ---------------------------------------------------------------------------
# CSpell
#
# Core ships two hand-curated dictionaries that between them know most Drupal and
# PHP jargon. Wiring them in is the difference between a spell check that finds
# real typos and one that reports 4,000 false positives and gets switched off.
# ---------------------------------------------------------------------------

config_cspell() {
  local base cache overlay
  cache=$(cache_dir)
  overlay="$cache/cspell.json"

  if base=$(project_config .cspell.json cspell.json cspell.config.json); then
    set_origin "project ($(basename "$base"))"
    emit_config "$base"
    return 0
  fi
  if [[ "${QA_CONFIG_SOURCE:-auto}" == "core" ]] && base=$(core_config core/.cspell.json); then
    set_origin "Drupal core"
    emit_config "$base"
    return 0
  fi

  base="$(assets_dir)/cspell.json"
  set_origin "bundled CI default"

  local -a defs=() dicts=()
  local d
  for d in drupal-dictionary dictionary; do
    local path="$QA_DRUPAL_ROOT/core/misc/cspell/$d.txt"
    if [[ -n "${QA_DRUPAL_ROOT:-}" && -f "$path" ]]; then
      defs+=("{\"name\":\"drupal-$d\",\"path\":\"$path\"}")
      dicts+=("\"drupal-$d\"")
    fi
  done
  # A per-project word list keeps domain jargon out of the shared config, which
  # is what the CI job's _cspell_updated_project_words.txt artifact is for.
  local words="$QA_PROJECT_ROOT/.cspell-project-words.txt"
  if [[ -f "$words" ]]; then
    defs+=("{\"name\":\"project-words\",\"path\":\"$words\"}")
    dicts+=("\"project-words\"")
  fi

  if [[ ${#defs[@]} -eq 0 ]]; then
    emit_config "$base"
    return 0
  fi

  local defs_json dicts_json
  defs_json=$(IFS=,; printf '[%s]' "${defs[*]}")
  dicts_json=$(IFS=,; printf '[%s]' "${dicts[*]}")
  jq --argjson defs "$defs_json" --argjson dicts "$dicts_json" \
    '.dictionaryDefinitions = ((.dictionaryDefinitions // []) + $defs)
     | .dictionaries = ((.dictionaries // []) + $dicts)' \
    "$base" > "$overlay"

  [[ -n "${QA_DRUPAL_ROOT:-}" ]] && set_origin "bundled CI default + core dictionaries"
  emit_config "$overlay"
}

# ---------------------------------------------------------------------------
# ESLint / Stylelint / Prettier
#
# Shareable configs and plugins resolve relative to the config file's directory,
# so a config sitting in the read-only Nix store cannot find airbnb-base. Stage
# the fallback configs into the cache directory next to a node_modules symlink
# and everything resolves the way ESLint expects.
# ---------------------------------------------------------------------------

stage_node_config() {
  local kind=$1 cache stage root
  cache=$(cache_dir)
  stage="$cache/$kind"
  mkdir -p "$stage"
  cp -f "$(assets_dir)/$kind"/.* "$stage/" 2>/dev/null || true
  if root=$(node_modules_root); then
    ln -sfn "$root/node_modules" "$stage/node_modules"
  fi
  printf '%s' "$stage"
}

# ESLint has two incompatible eras and Drupal spans both: Drupal 11 core ships
# .eslintrc.json files and pins ESLint 8, Drupal 12 core ships eslint.config.mjs
# and pins ESLint 9. The flags differ too — ESLint 9 rejects --ext and
# --no-eslintrc — so the config style decides everything, including which
# binary to run.
#
# Sets QA_ESLINT_FLAT, QA_ESLINT_BIN and QA_ESLINT_BASE alongside the config.
# The resolved Prettier options, as a JSON object, ready to inline into another
# tool's rule configuration.
#
# This matters more than it looks. eslint-plugin-prettier and stylelint-prettier
# do not use the config we resolved: they ask Prettier to find its own, by
# walking up from each linted file. So the same module lints differently
# depending on whether some ancestor directory happens to contain a
# .prettierrc.json — which is exactly the difference between a site that keeps
# one at its root and one that only has core's copy. Drupal's CI sidesteps this
# by symlinking core's .prettierrc.json into the project directory; inlining the
# options and switching off the file search achieves the same without writing
# into anyone's checkout.
#
# $1, when given, is a file glob whose Prettier `overrides` entry should be
# merged in (e.g. "*.css" for Stylelint).
prettier_options_json() {
  local want=${1:-}
  local file
  QA_CONFIG_ORIGIN_SAVE=$QA_CONFIG_ORIGIN
  file=$(config_prettier)
  QA_CONFIG_ORIGIN=$QA_CONFIG_ORIGIN_SAVE

  # Only JSON configs can be inlined. A .prettierrc.js is executable config; let
  # Prettier resolve that itself rather than guessing at its exports.
  jq -e . "$file" >/dev/null 2>&1 || return 1

  if [[ -n "$want" ]]; then
    jq -c --arg want "$want" '
      (. | del(.overrides, .["$schema"])) as $root
      | ($root + ((.overrides // [])
          | map(select(.files | if type == "array" then index($want) else . == $want end))
          | map(.options // {})
          | add // {}))' "$file"
  else
    jq -c 'del(.overrides, .["$schema"])' "$file"
  fi
}

config_eslint() {
  local base stage overlay flat=0 binbase=""

  if base=$(project_config eslint.config.js eslint.config.mjs eslint.config.cjs) \
     && binbase=$(eslint_base_at_least 9); then
    flat=1
    set_origin "project ($(basename "$base"))"
  elif base=$(project_config .eslintrc.json .eslintrc .eslintrc.js .eslintrc.yml); then
    set_origin "project ($(basename "$base"))"
  elif base=$(core_config core/eslint.passing.config.mjs core/eslint.config.mjs core/eslint.config.js) \
       && binbase=$(eslint_base_at_least 9); then
    # Core's flat config imports its plugins by name, so it only works from a
    # node_modules that has them — core's own.
    flat=1
    set_origin "Drupal core ($(basename "$base"))"
  elif base=$(core_config core/.eslintrc.passing.json) && [[ -d "$QA_DRUPAL_ROOT/core/node_modules" ]]; then
    # Core's eslintrc extends airbnb-base and plugin:prettier/recommended, which
    # resolve relative to the config file. Without core's node_modules installed
    # it would die with "Cannot find module", so fall through to the staged copy.
    set_origin "Drupal core (.eslintrc.passing.json)"
  else
    stage=$(stage_node_config eslint)
    base="$stage/.eslintrc.passing.json"
    set_origin "bundled core copy"
  fi

  QA_ESLINT_FLAT=$flat
  if [[ $flat -eq 1 ]]; then
    QA_ESLINT_BASE=$binbase
    QA_ESLINT_BIN=$(node_tool_in "$binbase" eslint)
  else
    # eslintrc needs an ESLint 8; the pinned toolbox is exactly that.
    QA_ESLINT_BASE=$(node_modules_root || true)
    QA_ESLINT_BIN=$(node_tool eslint || true)
  fi
  export QA_ESLINT_FLAT QA_ESLINT_BASE QA_ESLINT_BIN

  # The CI job writes a `.prettierignore` containing `*.yml` into the project
  # before running ESLint, so Prettier never reformats YAML — which matters,
  # because Prettier rewrites Drupal's single-quoted .info.yml values to double
  # quotes and nothing in Drupal wants that. Reproduce the effect with an
  # overlay config rather than by writing a file into someone's repository. A
  # project that ships its own .prettierignore has made this decision already,
  # so leave it alone.
  if [[ -f "$QA_PROJECT_ROOT/.prettierignore" ]]; then
    emit_config "$base"
    return 0
  fi

  if [[ $flat -eq 1 ]]; then
    # A flat overlay has to be real JavaScript that imports the base config.
    overlay="$(cache_dir)/eslint.overlay.mjs"
    local popts; popts=$(prettier_options_json) || popts=""
    {
      printf '// Generated by drupal-qa. Extends %s.\n' "$base"
      printf "import base from '%s';\n\n" "$base"
      printf 'const layers = Array.isArray(base) ? base : [base];\n'
      printf 'export default [\n'
      printf '  ...layers,\n'
      if [[ -n "$popts" ]]; then
        printf '  {\n'
        printf "    rules: { 'prettier/prettier': ['error', %s, { usePrettierrc: false }] },\n" "$popts"
        printf '  },\n'
      fi
      printf '  {\n'
      printf "    files: ['**/*.yml', '**/*.yaml'],\n"
      printf "    rules: { 'prettier/prettier': 'off' },\n"
      printf '  },\n'
      printf '];\n'
    } > "$overlay"
  else
    stage=${stage:-$(stage_node_config eslint)}
    overlay="$stage/.eslintrc.overlay.json"
    local popts; popts=$(prettier_options_json) || popts=""
    if [[ -n "$popts" ]]; then
      jq -n --arg base "$base" --argjson popts "$popts" '{
          root: true,
          extends: [$base],
          rules: { "prettier/prettier": ["error", $popts, { usePrettierrc: false }] },
          overrides: [{
            files: ["*.yml", "*.yaml"],
            rules: { "prettier/prettier": "off" }
          }]
        }' > "$overlay"
    else
      jq -n --arg base "$base" '{
          root: true,
          extends: [$base],
          overrides: [{
            files: ["*.yml", "*.yaml"],
            rules: { "prettier/prettier": "off" }
          }]
        }' > "$overlay"
    fi
  fi
  set_origin "$QA_CONFIG_ORIGIN + YAML formatting off (as CI does)"
  emit_config "$overlay"
}

config_stylelint() {
  local c stage base

  if base=$(project_config .stylelintrc.json .stylelintrc stylelint.config.js stylelint.config.mjs); then
    set_origin "project ($(basename "$base"))"
  elif base=$(core_config core/.stylelintrc.json core/stylelint.config.js core/stylelint.config.mjs) \
       && [[ -d "$QA_DRUPAL_ROOT/core/node_modules" ]]; then
    set_origin "Drupal core ($(basename "$base"))"
  else
    stage=$(stage_node_config stylelint)
    base="$stage/.stylelintrc.json"
    set_origin "bundled core copy"
  fi

  # stylelint-prettier has the same file-search behaviour as its ESLint
  # counterpart, so pin the options the same way — but only when the config
  # actually loads the plugin, or stylelint aborts with "Unknown rule".
  local popts=""
  if grep -q 'prettier' "$base" 2>/dev/null; then
    popts=$(prettier_options_json '*.css') || popts=""
  fi
  if [[ -z "$popts" ]]; then
    emit_config "$base"
    return 0
  fi

  c="$(cache_dir)/stylelintrc.overlay.json"
  jq -n --arg base "$base" --argjson popts "$popts" '{
      extends: [$base],
      rules: { "prettier/prettier": [true, $popts] }
    }' > "$c"
  set_origin "$QA_CONFIG_ORIGIN + pinned Prettier options"
  emit_config "$c"
}

config_prettier() {
  local c
  if c=$(project_config .prettierrc.json .prettierrc prettier.config.js .prettierrc.js); then
    set_origin "project ($(basename "$c"))"; emit_config "$c"; return 0
  fi
  if c=$(core_config core/.prettierrc.json); then
    set_origin "Drupal core"; emit_config "$c"; return 0
  fi
  set_origin "bundled core copy"
  emit_config "$(assets_dir)/prettierrc.json"
}

config_twig() {
  local c
  if c=$(project_config .twig-cs-fixer.php .twig-cs-fixer.dist.php twig-cs-fixer.php); then
    set_origin "project ($(basename "$c"))"; emit_config "$c"; return 0
  fi
  # Core only ships this from 11.5 onwards; older roots fall through.
  if c=$(core_config core/.twig-cs-fixer.php); then
    set_origin "Drupal core"; emit_config "$c"; return 0
  fi
  set_origin "bundled fallback"
  emit_config "$(assets_dir)/twig-cs-fixer.php"
}
