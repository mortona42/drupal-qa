#!/usr/bin/env bash
# Scaffold QA configuration into a module, theme or profile.
#
# Everything written here is optional: the tool already works with zero config by
# falling back to core's and the CI templates' defaults. `init` exists for the
# moment you want to *commit* the configuration so that contributors, editors and
# the real pipeline all agree with each other.
# shellcheck shell=bash

# Never clobber. Show what changed, and say so when nothing did.
write_file() {
  local path=$1 desc=$2
  if [[ -f "$path" && "${QA_FORCE:-0}" != "1" ]]; then
    printf '  %sskip%s  %-28s %s(exists)%s\n' "$C_DIM" "$C_RESET" "${path##*/}" "$C_DIM" "$C_RESET" >&2
    cat > /dev/null
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  cat > "$path"
  printf '  %swrite%s %-28s %s%s%s\n' "$C_GREEN" "$C_RESET" "${path##*/}" "$C_DIM" "$desc" "$C_RESET" >&2
}

cmd_init() {
  local root=$QA_PROJECT_ROOT
  local name=$QA_PROJECT_NAME
  local type=$QA_PROJECT_TYPE

  info "Scaffolding QA config for $type '$name' in $root"
  [[ "$type" == "unknown" ]] && warn "Could not identify this as a module/theme/profile. Writing generic config."

  local -a want=()
  if [[ ${#QA_INIT_WHAT[@]} -gt 0 ]]; then
    want=("${QA_INIT_WHAT[@]}")
  else
    want=(phpcs phpstan cspell editorconfig gitattributes)
    # Only scaffold front-end config where there is front-end code to lint.
    has_files_with_ext 'css' && want+=(stylelint prettier)
    has_files_with_ext 'js' && want+=(eslint prettier)
  fi

  local w
  for w in "${want[@]}"; do
    case $w in
      phpcs)        init_phpcs "$root" "$name" ;;
      phpstan)      init_phpstan "$root" ;;
      cspell)       init_cspell "$root" ;;
      eslint)       init_eslint "$root" ;;
      stylelint)    init_stylelint "$root" ;;
      prettier)     init_prettier "$root" ;;
      editorconfig) init_editorconfig "$root" ;;
      gitattributes) init_gitattributes "$root" ;;
      gitlab-ci)    init_gitlab_ci "$root" "$name" ;;
      gitignore)    init_gitignore "$root" ;;
      ddev)         install_ddev_command ;;
      envrc)        init_envrc "$root" ;;
      all)          : ;;
      *)            warn "Unknown config type '$w'." ;;
    esac
  done

  printf '\n' >&2
  info "Done. Check the result with: drupal-qa lint ${QA_TARGET_ARG:-.}"
}

init_phpcs() {
  local root=$1 name=$2
  write_file "$root/phpcs.xml.dist" "Drupal + DrupalPractice coding standards" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<ruleset name="$name">
  <description>PHP CodeSniffer configuration for $name.</description>

  <!-- The coding standards every Drupal project is held to. -->
  <rule ref="Drupal"/>

  <!--
    DrupalPractice catches things that are legal but discouraged (hard-coded
    configuration, t() on variables, and so on). It is advisory rather than
    mandatory; drop this line if it is too noisy for an existing codebase.
  -->
  <rule ref="DrupalPractice"/>

  <!-- Keep the extension list in the same order core uses. -->
  <arg name="extensions" value="engine,inc,info,install,module,php,profile,test,theme,yml"/>

  <!-- Readable output when run by a human; harmless in CI. -->
  <arg name="colors"/>
  <arg name="report-width" value="120"/>
  <arg value="sp"/>

  <file>.</file>

  <exclude-pattern>*/node_modules/*</exclude-pattern>
  <exclude-pattern>*/vendor/*</exclude-pattern>
  <exclude-pattern>*/dist/*</exclude-pattern>
</ruleset>
EOF
}

init_phpstan() {
  local root=$1
  write_file "$root/phpstan.neon.dist" "static analysis, level ${QA_PHPSTAN_LEVEL:-1}" <<EOF
# PHPStan configuration.
#
# Contrib CI defaults to level 0. Level 1 is a realistic target for most modules
# and catches genuinely broken code; raise it as the codebase allows.
#
# The mglaman/phpstan-drupal extension is what teaches PHPStan about Drupal's
# container, entity types and hooks. drupal-qa supplies it and points it at the
# detected Drupal root automatically.

includes:
  - phpstan-baseline.neon

parameters:
  level: ${QA_PHPSTAN_LEVEL:-1}

  fileExtensions:
    - php
    - module
    - inc
    - install
    - theme
    - profile
    - engine

  excludePaths:
    analyseAndScan:
      - */node_modules/*
      - */vendor/*

  reportUnmatchedIgnoredErrors: false

  ignoreErrors:
    # new static() is a documented Drupal best practice.
    - '#^Unsafe usage of new static#'
EOF
  # PHPStan refuses to start if an included baseline is missing, so always create
  # it, even empty. `drupal-qa baseline` fills it in.
  if [[ ! -f "$root/phpstan-baseline.neon" ]]; then
    write_file "$root/phpstan-baseline.neon" "empty baseline; fill with 'drupal-qa baseline'" <<'EOF'
# Pre-existing PHPStan errors that are accepted for now.
# Regenerate with: drupal-qa baseline
parameters:
  ignoreErrors: []
EOF
  fi
}

init_cspell() {
  local root=$1
  write_file "$root/.cspell.json" "spell check, extends core's dictionaries" <<'EOF'
{
    "$schema": "https://raw.githubusercontent.com/streetsidesoftware/cspell/main/cspell.schema.json",
    "version": "0.2",
    "language": "en-US",
    "allowCompoundWords": false,
    "minWordLength": 4,
    "dictionaries": [
        "companies",
        "css",
        "filetypes",
        "fonts",
        "html",
        "node",
        "php",
        "softwareTerms",
        "typescript",
        "project-words"
    ],
    "dictionaryDefinitions": [
        {
            "name": "project-words",
            "path": "./.cspell-project-words.txt",
            "addWords": true
        }
    ],
    "ignorePaths": [
        "**/node_modules/**",
        "**/vendor/**",
        "**/*.min.js",
        "**/*.min.css",
        "composer.lock",
        "package-lock.json",
        "yarn.lock"
    ],
    "ignoreRegExpList": [
        "^msgstr .*",
        "%[0-9][0-9A-F]",
        "\\Wi18n"
    ],
    "flagWords": [
        "blacklist->blocklist, denylist",
        "whitelist->allowlist",
        "e-mail",
        "grey"
    ],
    "overrides": [
        {
            "filename": "**/{*.engine,*.inc,*.install,*.module,*.profile,*.theme}",
            "languageId": "php"
        }
    ]
}
EOF
  if [[ ! -f "$root/.cspell-project-words.txt" ]]; then
    # Seeded with the jargon the scaffolded config files themselves introduce, so
    # that `drupal-qa init` is never immediately followed by a failing spell check.
    write_file "$root/.cspell-project-words.txt" "project vocabulary" <<'EOF'
# Words that are correct in this project but not in any standard dictionary.
# One per line, lower case. Add more with: drupal-qa cspell --accept-words
analyse
analysed
analyses
cspell
drupalpractice
mglaman
phpcbf
phpcs
phpstan
stylelint
twigcsfixer
EOF
  fi
}

init_eslint() {
  local root=$1
  write_file "$root/.eslintrc.json" "extends Drupal core's JS rules" <<'EOF'
{
  "root": true,
  "extends": ["airbnb-base", "plugin:prettier/recommended", "plugin:yml/recommended"],
  "env": { "browser": true, "es6": true, "node": false },
  "parserOptions": { "ecmaVersion": 2020 },
  "globals": {
    "Drupal": true,
    "drupalSettings": true,
    "jQuery": true,
    "once": true,
    "_": true
  },
  "rules": {
    "prettier/prettier": "error",
    "consistent-return": "off",
    "no-underscore-dangle": "off",
    "no-param-reassign": "off",
    "no-prototype-builtins": "off"
  }
}
EOF
}

init_stylelint() {
  local root=$1
  write_file "$root/.stylelintrc.json" "extends Drupal core's CSS rules" <<'EOF'
{
  "extends": ["stylelint-config-standard", "stylelint-prettier/recommended"],
  "plugins": ["stylelint-order"],
  "rules": {
    "alpha-value-notation": "number",
    "color-function-notation": "legacy",
    "custom-property-pattern": "^[a-z][-_a-z0-9]*$",
    "declaration-block-no-redundant-longhand-properties": null,
    "hue-degree-notation": "number",
    "import-notation": "string",
    "media-feature-range-notation": "prefix",
    "no-descending-specificity": null,
    "number-max-precision": 5,
    "selector-class-pattern": null
  }
}
EOF
}

init_prettier() {
  local root=$1
  write_file "$root/.prettierrc.json" "matches core's formatting" < "$(assets_dir)/prettierrc.json"
  if [[ ! -f "$root/.prettierignore" ]]; then
    write_file "$root/.prettierignore" "YAML is linted by ESLint, not Prettier" <<'EOF'
*.yml
*.yaml
node_modules/
vendor/
EOF
  fi
}

init_editorconfig() {
  local root=$1
  write_file "$root/.editorconfig" "editor defaults matching Drupal standards" <<'EOF'
# Drupal editor configuration.
# https://www.drupal.org/docs/develop/standards
root = true

[*]
end_of_line = LF
indent_style = space
indent_size = 2
charset = utf-8
trim_trailing_whitespace = true
insert_final_newline = true

[*.{md,txt}]
trim_trailing_whitespace = false

[composer.json]
indent_size = 4
EOF
}

init_gitattributes() {
  local root=$1
  write_file "$root/.gitattributes" "keeps dev-only files out of release archives" <<'EOF'
# Normalise line endings.
* text=auto eol=lf

# Files that belong in the repository but not in a packaged release.
/.gitlab-ci.yml   export-ignore
/.gitattributes   export-ignore
/.editorconfig    export-ignore
/phpcs.xml.dist   export-ignore
/phpstan.neon.dist export-ignore
/phpstan-baseline.neon export-ignore
/.cspell.json     export-ignore
/.cspell-project-words.txt export-ignore
/.eslintrc.json   export-ignore
/.stylelintrc.json export-ignore
/.prettierrc.json export-ignore
/.prettierignore  export-ignore
/tests            export-ignore
EOF
}

init_gitignore() {
  local root=$1
  write_file "$root/.gitignore" "ignores tool output and installed deps" <<'EOF'
/vendor/
/node_modules/
/.phpcs-cache
/.phpunit.result.cache
/phpstan-tmp/
/.twigcsfixercache
/.cspellcache
EOF
}

init_envrc() {
  local root=$1
  write_file "$root/.envrc" "direnv: drop into the QA shell automatically" <<'EOF'
# Requires direnv (https://direnv.net) and nix-direnv for caching.
# `direnv allow` once, and every shell in this directory has the QA tools.
use flake github:your-org/drupal-nix-tools
EOF
}

# The CI file a contrib project needs: three lines of include plus whatever it
# chooses to override. Written with the variables most projects end up wanting,
# commented out rather than guessed at.
init_gitlab_ci() {
  local root=$1 name=$2
  write_file "$root/.gitlab-ci.yml" "Drupal contrib pipeline" <<EOF
################
# GitLab CI for $name
#
# Docs: https://project.pages.drupalcode.org/gitlab_templates/
# Run it locally with: drupal-qa ci            (whole pipeline)
#                      drupal-qa ci phpcs      (one job)
#                      drupal-qa ci --list     (what is available)
################

include:
  - project: \$_GITLAB_TEMPLATES_REPO
    ref: \$_GITLAB_TEMPLATES_REF
    file:
      - '/includes/include.drupalci.main.yml'
      - '/includes/include.drupalci.variables.yml'
      - '/includes/include.drupalci.workflows.yml'

variables:
  # Pin the Drupal core version this project is tested against. Leave unset to
  # follow the current stable release.
  # _TARGET_CORE: '11.4.x-dev'

  # PHP version for the main pipeline. Defaults to core's minimum, which is the
  # version most likely to expose a syntax or typing mistake.
  # _TARGET_PHP: '8.3'

  # Turn a linting job from advisory into blocking by setting it to "0".
  # The templates default most of these to allow_failure: true.
  _PHPCS_ALLOW_FAILURE: '0'
  _PHPSTAN_ALLOW_FAILURE: '0'
  # _CSPELL_ALLOW_FAILURE: '0'
  # _ESLINT_ALLOW_FAILURE: '0'
  # _STYLELINT_ALLOW_FAILURE: '0'

  # Skip jobs that do not apply to this project.
  # SKIP_NIGHTWATCH: '1'
  # SKIP_UPGRADE_STATUS: '1'
EOF
}

# ---------------------------------------------------------------------------
# PHPStan baseline
# ---------------------------------------------------------------------------

cmd_baseline() {
  local bin; bin=$(php_tool phpstan) || die "phpstan is not available."
  local config; config=$(config_phpstan)
  local out="${QA_PROJECT_ROOT}/phpstan-baseline.neon"

  info "Generating a PHPStan baseline for $QA_PROJECT_NAME"
  log "  ${C_DIM}Everything PHPStan reports today becomes 'accepted'; only new problems fail afterwards.${C_RESET}"

  local -a args=(analyse --configuration="$config" --no-progress
                 --generate-baseline="$out" --allow-empty-baseline)
  [[ -n "${QA_PHPSTAN_LEVEL:-}" ]] && args+=(--level="$QA_PHPSTAN_LEVEL")
  if [[ -n "${QA_COMPOSER_ROOT:-}" && -f "$QA_COMPOSER_ROOT/vendor/autoload.php" ]]; then
    args+=(--autoload-file="$QA_COMPOSER_ROOT/vendor/autoload.php")
  fi

  # Generating into the project root keeps the paths in the baseline relative and
  # portable, which is what makes it usable in CI as well as locally.
  ( cd "$QA_PROJECT_ROOT" && php_run "$bin" "${args[@]}" "$QA_PROJECT_ROOT" ) || true

  if [[ -f "$out" ]]; then
    local count
    count=$(grep -c 'message:' "$out" 2>/dev/null || echo 0)
    info "Wrote ${out/#$QA_PROJECT_ROOT\//} with $count accepted error(s)."
    grep -q 'phpstan-baseline' "$QA_PROJECT_ROOT"/phpstan.neon* 2>/dev/null \
      || warn "Remember to add 'includes: [phpstan-baseline.neon]' to your phpstan config."
  else
    warn "No baseline was produced; PHPStan may have found nothing to accept."
  fi
}
