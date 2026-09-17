# QA tooling for this project

Everything is provided by Nix; nothing is added to `composer.json`.

```sh
direnv allow          # or: nix develop

drupal-qa info        # what was detected, and which config each tool will use
drupal-qa lint        # every static check CI runs
drupal-qa lint --changed   # only the files you touched
drupal-qa fix         # apply every auto-fixer
drupal-qa test        # PHPUnit, with SQLite and a headless browser provided
drupal-qa ci          # the real GitLab pipeline, in its own containers
```

`drupal-qa` falls back to Drupal core's and the GitLab templates' own
configuration for any tool this project does not configure itself, so a clean
local run predicts a clean pipeline. Commit your own config with
`drupal-qa init` when you want to diverge.
