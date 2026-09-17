# The PHP side of the QA toolchain, built from a committed composer.lock.
#
# Deliberately NOT installed into the user's project: adding drupal/coder or
# phpstan-drupal to a contrib module's require-dev is how dependency conflicts
# start, and it would modify the very composer.json that the `composer-lint` job
# validates. The toolbox lives in the Nix store and is pointed at the project
# from outside, which is also what makes the first run instant and offline.
#
# The lock is resolved against PHP 8.3 (Drupal 11's minimum), so one lock serves
# 8.3, 8.4 and 8.5 without re-resolution.
{ php, lib }:

php.buildComposerProject2 {
  pname = "drupal-qa-php-toolbox";
  version = "0.1.0";
  src = ../toolbox/php;
  composerLock = ../toolbox/php/composer.lock;

  # Refresh by setting this to lib.fakeHash and reading the expected value out of
  # the build failure, or with `nix build .#phpToolbox --rebuild`.
  vendorHash = "sha256-c9Cfo0yvArMOQApTR4qF5u2/GEMAIS5YB7u/ABkgaOE=";

  # PHPStan ships as a signed phar. patchShebangs rewrites the `#!/usr/bin/env
  # php` line inside it, which changes the file length and invalidates the
  # SHA512 signature, so every invocation dies with "broken signature". Nothing
  # here is executed via its shebang — the CLI always calls these scripts as
  # `php <script>` with an explicitly chosen interpreter — so patching them buys
  # nothing and costs us PHPStan.
  dontPatchShebangs = true;

  # dealerdirect/phpcodesniffer-composer-installer would normally register the
  # sniff directories, but Composer plugins do not run in the Nix sandbox. Write
  # the same configuration by hand, using the final store paths. Without this,
  # `phpcs -i` lists only the PEAR/PSR standards and "Drupal" is not a standard
  # PHPCS has ever heard of.
  postInstall = ''
    vendorDir="$out/share/php/${"drupal-qa-php-toolbox"}/vendor"
    conf="$vendorDir/squizlabs/php_codesniffer/CodeSniffer.conf"
    paths="$vendorDir/drupal/coder/coder_sniffer,$vendorDir/sirbrillig/phpcs-variable-analysis,$vendorDir/slevomat/coding-standard,$vendorDir/micheh/phpcs-gitlab"
    cat > "$conf" <<EOF
    <?php
     \$phpCodeSnifferConfig = array (
      'installed_paths' => '$paths',
    );
    EOF
    # The heredoc above is indented for readability; strip it back out.
    sed -i 's/^    //' "$conf"
  '';

  meta = {
    description = "Pinned PHPCS/PHPStan/Twig CS Fixer toolchain for Drupal QA";
    license = lib.licenses.gpl2Plus;
    platforms = lib.platforms.unix;
  };
}
