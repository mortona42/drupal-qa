# drupal-nix-tools

Run Drupal's CI code quality tools and tests locally, reproducibly, with nothing
installed into your project.

```sh
nix run github:your-org/drupal-nix-tools -- lint my_module
```

Works on core, contrib and custom code, alongside DDEV, with or without a Drupal
site present.

---

## Why

Running Drupal's checks locally is normally a small research project. PHPCS needs
`drupal/coder` and the right `installed_paths`. PHPStan needs `phpstan-drupal` and
an autoloader. ESLint needs a `yarn install` inside `web/core`. Adding any of it
to a contrib module's `composer.json` risks the dependency conflicts that
`composer-lint` then complains about. So people skip it, push, and find out from
the pipeline twenty minutes later.

This flake takes the other approach:

- **The toolchain lives in the Nix store, never in your project.** Your
  `composer.json` is untouched — which matters, because that file is itself one
  of the things CI validates.
- **Zero configuration is the working default.** A module with no config files
  is checked with exactly the rules its GitLab pipeline would use: core's
  ESLint, Stylelint, Prettier and Twig configs, and the contrib defaults from
  `gitlab_templates` for PHPCS, PHPStan and CSpell.
- **Tests need no environment setup.** `drupal-qa test` provisions SQLite, a web
  server and a headless Chrome itself. No `SIMPLETEST_DB`, no
  `MINK_DRIVER_ARGS_WEBDRIVER`.
- **Nothing is a black box.** `drupal-qa info` shows every detected path and
  which config each tool resolved to; `-v` shows the exact command, so you can
  always go around the wrapper.

---

## Install

Ad-hoc, no install:

```sh
nix run github:your-org/drupal-nix-tools -- lint
```

A shell with everything on `PATH`:

```sh
nix develop github:your-org/drupal-nix-tools
```

Permanently:

```sh
nix profile install github:your-org/drupal-nix-tools
```

Per project, so everyone gets the same versions — add a `flake.nix` and `.envrc`
with [direnv](https://direnv.net):

```sh
nix flake init -t github:your-org/drupal-nix-tools#contrib
direnv allow
```

---

## Quick start

```sh
drupal-qa info              # what was detected, and which config each tool will use
drupal-qa doctor            # is anything missing?

drupal-qa lint              # every static check, on the module you are standing in
drupal-qa lint my_module    # by machine name, from anywhere in the project
drupal-qa lint web/modules/custom   # or by path
drupal-qa lint --changed    # only the files you touched
drupal-qa fix               # apply every auto-fixer

drupal-qa test my_module                    # PHPUnit
drupal-qa test my_module --type=kernel
drupal-qa test my_module --type=functional-js --ddev

drupal-qa ci                # the real GitLab pipeline, in its own containers
drupal-qa ci phpcs          # one job from it

drupal-qa init my_module    # commit the configuration
drupal-qa baseline my_module  # accept today's PHPStan errors
```

### The target argument

Every checking command takes an optional target, which can be:

| Form | Example |
| --- | --- |
| nothing | `drupal-qa lint` — the module you are standing in |
| a path | `drupal-qa lint web/modules/custom/my_module` |
| a single file | `drupal-qa phpcs src/Plugin/Block/Foo.php` |
| a machine name | `drupal-qa lint commerce_product` |

Machine names are resolved inside the detected Drupal root, preferring
`modules/custom` over `modules/contrib` over `core/modules` — when a name exists
in more than one place you almost certainly mean the one you can edit.

---

## What it runs

Each command corresponds to a job in Drupal's GitLab CI templates.

| Command | Tool | CI job |
| --- | --- | --- |
| `php-lint` | php-parallel-lint | part of `composer-lint` |
| `composer-lint` | `composer validate` | `composer-lint` |
| `phpcs` / `phpcbf` | PHP_CodeSniffer + drupal/coder | `phpcs` |
| `phpstan` | PHPStan + mglaman/phpstan-drupal | `phpstan` |
| `cspell` | CSpell | `cspell` |
| `eslint` | ESLint 8 | `eslint` |
| `stylelint` | Stylelint | `stylelint` |
| `prettier` | Prettier | via the ESLint/Stylelint plugins |
| `twig` | Twig CS Fixer | `twig-cs-fixer` |
| `test` | PHPUnit | `phpunit` |
| `nightwatch` | Nightwatch | `nightwatch` |

`lint` runs all the static ones; `fix` runs the ones that can repair what they
find. Restrict either with `--only=phpcs,phpstan` or `--skip=cspell`.

---

## Where configuration comes from

This is the part that decides whether a green local run means a green pipeline,
so it follows the CI templates exactly. For each tool, in order:

1. **Your project's own config file**, if it has one.
2. **Drupal core's config**, for ESLint, Stylelint, Prettier and Twig CS Fixer —
   these are the files the CI jobs symlink to. Used only when core's
   `node_modules` is actually installed, since core's ESLint config extends
   packages that resolve from there.
3. **The contrib default bundled here**, for PHPCS, PHPStan and CSpell. CI
   fetches these from `gitlab_templates/assets`; they ship in this flake so the
   first run needs no network.

`drupal-qa info` prints the decision for every tool. Override the whole chain
with `--config-source=project|core|bundled`; `--config-source=core` is how you
check a contrib module against core's own stricter PHPCS and PHPStan rules.

Two details worth knowing:

- **Core's dictionaries are wired into CSpell** when a Drupal root is present.
  Without them a spell check on Drupal code reports thousands of false positives
  and gets switched off within a day.
- **YAML is linted but not Prettier-formatted**, because Prettier rewrites
  `description: 'Foo'` in an `.info.yml` to double quotes and CI does not. The CI
  job achieves this by writing a `.prettierignore` into your checkout; this tool
  uses a generated overlay config instead, so your repository stays clean.

---

## Working with DDEV

Lint tools run **on the host**, from the Nix store. That is the whole point:
`ddev exec phpcs` pays Docker's process-start cost on every run and needs the QA
tools installed in the container.

What DDEV is genuinely better at is *services*, so tests can borrow them:

```sh
drupal-qa test my_module --type=functional --ddev
```

This points PHPUnit at DDEV's MariaDB on its published host port and uses the
project's DDEV URL as `SIMPLETEST_BASE_URL`, while PHP still runs natively.

For muscle memory, install a `ddev qa` host command:

```sh
drupal-qa init --with=ddev
ddev restart
ddev qa lint
```

Without `--ddev`, tests use SQLite in a temp directory and PHP's built-in web
server — which needs no containers running at all and is considerably faster for
Unit and Kernel tests.

---

## Testing

```sh
drupal-qa test my_module                      # everything under the module's tests/
drupal-qa test my_module --type=unit,kernel
drupal-qa test my_module --group=my_group
drupal-qa test my_module --filter=testSomethingSpecific
drupal-qa test --type=functional-js           # headless Chrome, provided
drupal-qa test my_module --coverage           # pcov, HTML report
drupal-qa test my_module --xdebug             # step debugging
drupal-qa test my_module --deprecations       # show deprecation details
drupal-qa test my_module --keep               # keep scratch files on failure
```

Deprecation details are hidden by default. A contrib test run reports dozens of
deprecations triggered by core itself, and they bury the actual results; core's
`phpunit.xml.dist` turns the display on, so a derived copy in the cache
directory turns it back off rather than editing anything in your checkout.

Page dumps from failing Functional tests land in
`sites/simpletest/browser_output` — Drupal's own location, so the URL printed in
the failure output actually resolves.

PHPUnit itself is deliberately taken from the **project's** `vendor/bin`, never
from the toolbox: `core/tests/bootstrap.php` and the listeners in core's
`phpunit.xml.dist` are coupled to the installed core version. If it is missing:

```sh
composer require --dev drupal/core-dev -W
```

Infrastructure is provisioned only when the selected tests need it — a Unit test
run never starts a browser.

---

## Running the real pipeline

`drupal-qa lint` reproduces what the CI jobs *check*. When the pipeline fails and
your local run does not, reproduce the jobs themselves:

```sh
drupal-qa ci --list      # jobs the pipeline defines
drupal-qa ci             # all of them
drupal-qa ci phpcs       # just one
drupal-qa ci --dirty     # let jobs write into the working tree, for debugging
```

This drives [`gitlab-ci-local`](https://github.com/firecow/gitlab-ci-local) with
the setup Drupal's templates require, all of which fails obscurely when missing:
the remote variables file (or every semantic version label — `$CORE_STABLE`,
`$CORE_PHP_MIN`, … — expands to nothing), and explicit
`_GITLAB_TEMPLATES_REPO`/`_GITLAB_TEMPLATES_REF` values, because includes are
resolved before the remote variables are applied.

Two requirements it checks for you and explains if unmet:

- **Docker**, since these are the real CI containers.
- **An `origin` remote on a drupal.org host.** `gitlab-ci-local` decides which
  GitLab server hosts the CI templates from that remote; without one it tries
  gitlab.com and fails with an SSH permission error that mentions nothing
  relevant. An SSH remote works anonymously:
  `git remote add origin git@git.drupal.org:project/<name>.git`

---

## Setting up a project

```sh
drupal-qa init my_module
```

Writes only what applies — front-end configs are skipped for a module with no
JS or CSS — and never overwrites an existing file without `--force`.

```sh
drupal-qa init my_module --with=phpcs,phpstan,gitlab-ci
drupal-qa init --with=ddev        # the `ddev qa` host command
drupal-qa init --with=envrc       # direnv integration
```

Available: `phpcs`, `phpstan`, `cspell`, `eslint`, `stylelint`, `prettier`,
`editorconfig`, `gitattributes`, `gitignore`, `gitlab-ci`, `ddev`, `envrc`.

### Inheriting a codebase with thousands of warnings

Two tools make this bearable:

```sh
drupal-qa lint --changed     # judge only what you touched
drupal-qa baseline my_module # accept today's PHPStan errors; fail only on new ones
```

`--changed` compares against the merge base with your upstream branch, so a
long-lived feature branch does not re-report itself on every run.

---

## Choosing a PHP version

```sh
drupal-qa lint --php=8.4
drupal-qa test --php=8.5
```

8.3, 8.4 and 8.5 are provided. The default is **8.3**, Drupal 11's minimum and
what contrib CI targets — the version most likely to catch a syntax or typing
mistake you would otherwise ship.

---

## Caching

Per-project caches for PHPCS, PHPStan, ESLint, Stylelint, CSpell and Twig CS
Fixer live under `${XDG_CACHE_HOME:-~/.cache}/drupal-qa/`. A repeat run is
typically a few seconds. `drupal-qa info` prints the directory; deleting it is
always safe.

---

## Maintaining this flake

The pinned toolchains are two lock files.

```sh
# PHP tools (PHPCS, PHPStan, Twig CS Fixer, parallel-lint)
nix develop -c composer update -d toolbox/php --no-install
nix build .#phpToolbox        # read the new vendorHash from the failure
# edit nix/toolbox-php.nix

# JS tools (ESLint, Stylelint, Prettier, CSpell)
nix develop -c npm install --prefix toolbox/node --package-lock-only
nix build .#nodeToolbox       # read the new npmDepsHash from the failure
# edit nix/toolbox-node.nix

nix flake check               # shellcheck, plus a CLI smoke test
```

Two constraints to keep in mind when bumping:

- `toolbox/php/composer.json` pins `config.platform.php` to **8.3.0**, so one
  lock resolves for all three PHP versions. Raising it breaks 8.3.
- ESLint is pinned to the **8.x** line. Core still ships `.eslintrc` files and
  ESLint 9 reads only flat config, so 9 would silently ignore core's rules.

Version pins to review when Drupal's minimums move are in `flake.nix`
(`phpVersions`, `defaultPhpVersion`) and `toolbox/php/composer.json`. The
authoritative values live in
[`gitlab_templates/includes/include.drupalci.hidden-variables.yml`](https://git.drupalcode.org/project/gitlab_templates/-/blob/main/includes/include.drupalci.hidden-variables.yml).

---

## Known limits

- **Nightwatch needs core's `node_modules`.** Its test runner and page objects
  live in core and are not reproducible from a standalone lock; run
  `yarn install` in `web/core` once.
- **PHPStan without a Drupal root** reports "class not found" for everything
  Drupal provides. Working on a standalone module checkout, point at a site with
  `--core=<path>` — the warning says so at the time.
- **`drupal-qa ci` needs Docker** and a drupal.org `origin` remote; see above.
- **`--config-source=core` for PHPStan needs a `drupal/drupal` checkout.** Core's
  `phpstan.neon.dist` references `../composer/`, which a
  `drupal/recommended-project` install does not have. The tool detects this and
  falls back to the contrib default with an explanation.
- **Twig CS Fixer's config ships with core from 11.5**; on older core a bundled
  fallback is used, which registers Drupal's `{% trans %}` token parser only when
  a Drupal autoloader is available.

---

## Licence

GPL-2.0-or-later, matching Drupal.
