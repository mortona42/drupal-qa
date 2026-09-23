# Intro
Drupal code qa/test tools implemented in nix.

This is vibe coded with minimal review, be warned!

However, it works well for me and is quite easy to use, and propbably won't break anything.
___

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
| `eslint` | ESLint 8 or 9 | `eslint` |
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
- **A project's ESLint config adds to core's, it does not replace it.** The CI
  job arranges this by symlinking core's `.eslintrc.passing.json` into the
  directory above the project so both apply; the generated overlay layers them
  explicitly instead, project last so it wins on conflicts. That matters because
  a module often adds an `.eslintrc.json` for one reason — declaring a global
  like `Prism` — and would otherwise silently lose every Drupal rule. A project
  that sets `"root": true` is taken at its word and used alone.
- **The `.eslintrc` cascade is switched off.** Drupal scaffolds
  `web/.eslintrc.json` into every site, extending `core/.eslintrc.json`, so
  ESLint walking up from a module would drag that in and fail on
  `extends: airbnb-base` unless core's `node_modules` is installed.
- **Both ESLint eras are handled.** Drupal 11 core ships `.eslintrc.json` and
  pins ESLint 8; Drupal 12 core ships `eslint.config.mjs` and pins ESLint 9,
  which rejects `--ext` and `--no-eslintrc` outright. The config style decides
  which binary runs: a flat config uses the ESLint next to it (its plugins are
  imported by name and only resolve from there), an `.eslintrc` uses the pinned
  ESLint 8 from the toolbox.
- **Node binaries are checked before use.** A `node_modules` installed under an
  older Node has tools that refuse to start; the run falls back to the pinned
  toolbox instead of blaming your code.
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

### When phpcbf will not fix something

PHPCS marks each message `[x]` or `[ ]` in its report. Only `[x]` messages can be
fixed automatically, and the distinction is deliberate: rewrapping a line that
exceeds 80 characters, removing a `dpm()` call or writing a missing description
all need a person, so PHPCS declines rather than guessing.

`drupal-qa phpcbf` now says how many it had to leave:

```
pass   phpcbf    fixed 200, 61 not auto-fixable
```

Two other things surprise people, and neither is a bug:

- **The fixer can create new violations.** Fixing `FunctionComment.Missing`
  inserts an empty `/** */` block, which then reports `DocComment.Empty` and
  `DocComment.MissingShort` — both `[ ]`. That is PHPCS saying "I have put the
  docblock where it belongs; the sentence is yours."
- **Running it twice changes nothing.** PHPCBF already loops internally until a
  file stops changing.

### Will a warning fail CI?

PHPCS exits non-zero for warnings alone, so a warning-only run is a failed
`phpcs` job. Whether that *blocks* anything is a separate question, and the
answer is in the pipeline, not the tool:

```sh
drupal-qa ci --list
```

```
phpcs        validate  on_success  allow_failure: true
composer-lint validate on_success  allow_failure: false
phpunit      test      on_success  allow_failure: false
```

Drupal's CI templates mark every linting job `allow_failure: true` by default:
reported and shown as failed, but not blocking. A project makes one blocking with
`_PHPCS_ALLOW_FAILURE: '0'` — and because warnings alone fail phpcs, that turns a
single over-long line into a blocked merge request. `drupal-qa init --gitlab-ci`
scaffolds exactly that for phpcs and phpstan, with a comment saying so; delete
the two lines to follow the template defaults.

The middle ground is to block on errors and merely report warnings:

```yaml
_PHPCS_EXTRA: '--runtime-set ignore_warnings_on_exit 1'
```

Locally, the summary shows the split, because that is what decides the outcome:

```
FAIL   phpcs    0 error(s), 1 warning(s)
```

### Keeping the spell check useful

CSpell is the check people switch off first, because Drupal code is full of
legitimate words no dictionary has. Core's own dictionaries are wired in
automatically; the rest go in the project dictionary, which by convention (and
by Drupal CI's `_CSPELL_DICTIONARY` default) is `.cspell-project-words.txt`.

```sh
drupal-qa cspell my_module --accept-words --dry-run   # what would be accepted
drupal-qa cspell my_module --accept-words             # accept it
drupal-qa cspell my_module --accept-words --changed   # only words you introduced
drupal-qa cspell my_module --accept-words --dictionary=my-words.txt
```

Accepting is a separate command, never part of `drupal-qa fix`, because it
asserts that a word is *not* a typo — a fixer that silently blesses `recieve` is
worse than no spell check. Hence `--dry-run`, and `--changed`, which limits the
list to files you have touched so an inherited backlog stays out of it.

The dictionary file is picked in this order: `--dictionary`, then any `.txt`
dictionary the project's own CSpell config declares, then the Drupal default.
Afterwards the check is re-run: if the words are still reported, your config does
not actually load the file, and you are told what to add rather than left with a
dictionary nothing reads.

For a word that belongs in exactly one file, prefer a CSpell inline comment
there — `cspell:ignore somethingveryspecific` — over the shared dictionary.

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

The version is **detected from the project**, because getting it wrong produces
failures that look like code problems and are not. When a project installs its
own QA tools, those are the ones used (they are version-matched to its core), and
Composer's generated `platform_check.php` aborts with a fatal error if the
interpreter is older than the installed packages require. Every PHP tool then
"fails" for reasons unrelated to your code.

Detection order:

1. `--php=8.4`, if you pass it.
2. DDEV's `php_version`, including `.ddev/config.*.yaml` overrides — what the
   site actually runs.
3. `composer.json`: `config.platform.php`, else the `require.php` constraint.
4. Otherwise 8.3, Drupal 11's minimum and what contrib CI targets.

Whatever that produces is then **raised** if `vendor/composer/platform_check.php`
demands more. 8.3, 8.4 and 8.5 are provided; if a project wants something else
you are told, rather than left to decode a platform-check backtrace.

`drupal-qa info` prints the chosen version and where it came from. The chosen
interpreter also goes to the front of `PATH`, so Composer and any `vendor/bin`
script run through its shebang agree with it.

---

## Running the tools yourself

The wrapper is a convenience, not a cage. Three ways out of it, in increasing
order of independence.

**See the command it ran.** Every check accepts `-v`:

```sh
drupal-qa phpcs my_module -v
```

It prints the full command — config file, standard, installed_paths, cache
location — which you can paste and edit.

**Run a tool with the project's environment.** `exec` hands you the PHP version
detected for this project and the right copies of the tools on `PATH`, then gets
out of the way:

```sh
drupal-qa exec phpcs --standard=Drupal src/
drupal-qa exec phpstan analyse --level=6 src/
drupal-qa exec --toolchain=pinned phpcs --version   # the pinned copy instead
drupal-qa exec --php=8.3 php -v                     # a different interpreter
```

Its own flags may precede the command; the first bare word starts the command,
and everything after belongs to it. Use `--` if your command starts with a dash.
`drupal-qa env` prints the same settings as shell exports for
`eval "$(drupal-qa env)"`.

**Put them on `PATH` for a whole session:**

```sh
nix develop
phpcs --standard=Drupal src/
phpstan analyse src/
eslint js/
```

This matters more than it sounds. Without it, `phpcs` in your shell is whatever
is first on `PATH` — usually a global Composer install that has never heard of
the Drupal standard, so `--standard=Drupal` fails with an error that looks like a
configuration problem. The shell puts the pinned copies first, with `Drupal`,
`DrupalPractice`, `VariableAnalysis` and `SlevomatCodingStandard` registered.

One difference worth knowing: tools on `PATH` in the dev shell run under the
flake's default PHP, because a shell has no single project. `drupal-qa` and
`drupal-qa exec` detect the version per project. If the project's packages
require a newer PHP, use `exec`.

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
