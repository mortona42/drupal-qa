#!/usr/bin/env bash
# Run the project's real GitLab pipeline locally, via gitlab-ci-local.
#
# `drupal-qa lint` reproduces what the CI jobs *check*; this reproduces the jobs
# themselves, in the same containers. That is what you want when the pipeline
# fails and the local lint run does not — a different PHP version, a missing
# dependency, a job that only runs on merge requests.
#
# Three Drupal-specific pieces of setup are needed, and getting any of them
# wrong produces an error that does not mention the real cause:
#
#  * --remote-variables, or every semantic version label ($CORE_STABLE,
#    $CORE_PHP_MIN, ...) expands to an empty string.
#  * _GITLAB_TEMPLATES_REPO and _GITLAB_TEMPLATES_REF, because gitlab-ci-local
#    resolves `include:` before the remote variables file is applied, so the
#    include would ask for ref "HEAD" of an unset project.
#  * An `origin` remote on git.drupalcode.org, which is how gitlab-ci-local
#    decides which GitLab server the include lives on.
# shellcheck shell=bash

QA_TEMPLATES_REPO_DEFAULT='project/gitlab_templates'
QA_TEMPLATES_REF_DEFAULT='default-ref'
QA_TEMPLATES_VARS_DEFAULT='git@git.drupal.org:project/gitlab_templates=includes/include.drupalci.variables.yml=main'

ci_project_dir() {
  # gitlab-ci-local must run where .gitlab-ci.yml lives.
  local dir=$QA_PROJECT_ROOT
  [[ -f "$dir/.gitlab-ci.yml" ]] && { printf '%s' "$dir"; return 0; }
  [[ -n "${QA_GIT_ROOT:-}" && -f "$QA_GIT_ROOT/.gitlab-ci.yml" ]] && { printf '%s' "$QA_GIT_ROOT"; return 0; }
  return 1
}

# gitlab-ci-local resolves `include: project:` against the host of the repo's
# `origin` remote. Without one it silently tries gitlab.com and fails with an
# SSH permission error that says nothing about the actual problem.
ci_check_remote() {
  local dir=$1 url
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || url=""
  if [[ -z "$url" ]]; then
    warn "This repository has no 'origin' remote."
    warn "gitlab-ci-local works out which GitLab server hosts the Drupal CI"
    warn "templates from that remote, and will otherwise try gitlab.com and fail."
    warn "Add one:  git remote add origin git@git.drupal.org:project/<name>.git"
    return 1
  fi
  if [[ "$url" != *drupal* ]]; then
    warn "The 'origin' remote is $url, which is not a drupal.org host."
    warn "The CI template include will be looked for on that server."
  fi
  if [[ "$url" == https://* ]]; then
    warn "The 'origin' remote uses HTTPS. gitlab-ci-local fetches includes over SSH,"
    warn "so the template fetch may fail; an SSH remote avoids it."
  fi
  return 0
}

ci_common_args() {
  QA_CI_ARGS=(
    --remote-variables "${QA_TEMPLATES_VARS:-$QA_TEMPLATES_VARS_DEFAULT}"
    --variable "_GITLAB_TEMPLATES_REPO=${QA_TEMPLATES_REPO:-$QA_TEMPLATES_REPO_DEFAULT}"
    --variable "_GITLAB_TEMPLATES_REF=${QA_TEMPLATES_REF:-$QA_TEMPLATES_REF_DEFAULT}"
  )
}

cmd_ci() {
  command -v gitlab-ci-local >/dev/null 2>&1 || die "gitlab-ci-local is not available. Enter the dev shell with 'nix develop', or install it."
  command -v docker >/dev/null 2>&1 || warn "Docker was not found on PATH; gitlab-ci-local needs a container runtime."

  local dir
  dir=$(ci_project_dir) || die "No .gitlab-ci.yml found in $QA_PROJECT_ROOT. Create one with: drupal-qa init --gitlab-ci"
  ci_check_remote "$dir" || true

  ci_common_args
  local -a args=("${QA_CI_ARGS[@]}")
  # Shell isolation makes artifacts behave the way they do on a real runner.
  # Without it, jobs write straight into the working tree — occasionally useful
  # for debugging, which is what --dirty is for, but surprising by default.
  [[ "${QA_CI_DIRTY:-0}" == "1" ]] || args+=(--shell-isolation)
  [[ "${QA_VERBOSE:-0}" == "1" ]] && args+=(--verbose)
  [[ -n "${QA_EXTRA_CI:-}" ]] && read -ra extra <<< "$QA_EXTRA_CI" && args+=("${extra[@]}")

  info "Running GitLab CI from $dir"
  if [[ $# -gt 0 ]]; then info "Jobs: $*"; else info "Jobs: (all)"; fi

  local status=pass
  ( cd "$dir" && run_cmd gitlab-ci-local "${args[@]}" "$@" ) || status=fail
  record_result "gitlab-ci" "$status"
}

cmd_ci_list() {
  command -v gitlab-ci-local >/dev/null 2>&1 || die "gitlab-ci-local is not available."
  local dir
  dir=$(ci_project_dir) || die "No .gitlab-ci.yml found in $QA_PROJECT_ROOT."
  ci_check_remote "$dir" || true
  ci_common_args
  ( cd "$dir" && run_cmd gitlab-ci-local --list "${QA_CI_ARGS[@]}" )
}
