# A PHP interpreter configured the way Drupal expects it.
#
# nixpkgs' PHP already compiles in everything Drupal core requires — ctype, curl,
# dom, fileinfo, filter, gd, iconv, intl, mbstring, openssl, pdo + the sqlite,
# mysql and pgsql drivers, session, simplexml, tokenizer, xml, xmlreader,
# xmlwriter, zip, zlib, sodium, opcache and more. Verified against php83, php84
# and php85; `drupal-qa doctor` re-checks the ones Drupal cannot run without, so
# a future nixpkgs change that drops one is reported rather than discovered
# halfway through a test run.
#
# Only the genuinely-absent extensions are added below. Requesting one that is
# already built in is not harmless: PHP then prints `Module "xml" is already
# loaded` on every startup, which corrupts any caller that captures its output.
{ basePhp, lib }:

basePhp.buildEnv {
  extensions =
    { all, enabled }:
    let
      extras = with all; [
        # Cache backends that Drupal and common contrib test against.
        apcu
        igbinary
        memcached
        redis

        # Used by core's archive handling and by some contrib.
        bz2
        yaml

        # Coverage and debugging. pcov is several times faster than Xdebug for
        # line coverage and is what `--coverage` selects by default; Xdebug is
        # here for `--xdebug` step debugging. Both are inert until asked for.
        pcov
        xdebug
      ];
      # Belt and braces in case a future nixpkgs moves one of these into the
      # default set. Compare on the bare extension name: derivation identity is
      # not reliable, and `getName` yields "php-apcu" where `extensionName`
      # yields "apcu".
      nameOf = e: lib.removePrefix "php-" (e.extensionName or (lib.getName e));
      enabledNames = map nameOf enabled;

      # None of the extras is load-bearing for linting or for core's test suite,
      # and nixpkgs marks one broken from time to time per PHP version (igbinary
      # on 8.4/8.5 at the time of writing). Dropping a broken one keeps all three
      # PHP versions buildable instead of taking the whole flake down with it;
      # `drupal-qa doctor` reports what is actually present.
      usable = lib.filter (e: !(e.meta.broken or false)) extras;
    in
    enabled ++ lib.filter (e: !(lib.elem (nameOf e) enabledNames)) usable;

  extraConfig = ''
    ; Every consumer of this PHP is a long-running CLI QA tool, never a web
    ; request, so the production-oriented defaults are the wrong ones here.
    memory_limit = -1
    max_execution_time = 0
    error_reporting = E_ALL
    display_errors = On
    display_startup_errors = On
    log_errors = On
    date.timezone = UTC
    assert.active = 1
    zend.assertions = 1

    ; Tests send mail. Swallow it rather than failing or, worse, delivering it.
    sendmail_path = /bin/true

    ; Opcache pays for itself on PHPStan and PHPUnit runs, but never with
    ; timestamp validation off: an edited file must be seen on the next run.
    opcache.enable_cli = 1
    opcache.validate_timestamps = 1
    opcache.memory_consumption = 256
    opcache.max_accelerated_files = 100000

    ; A loaded Xdebug slows every command by 2-3x. Both coverage drivers stay
    ; dormant; the CLI switches one on per-invocation with -d directives.
    pcov.enabled = 0
    xdebug.mode = off
  '';
}
