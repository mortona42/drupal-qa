# The JavaScript side of the QA toolchain (ESLint, Stylelint, Prettier, CSpell).
#
# Drupal core CI runs these out of web/core/node_modules after a `yarn install`.
# Reproducing that locally means a multi-minute yarn run against a registry that
# may be unreachable. Instead the same tool versions core pins are built once
# from a committed package-lock.json. `drupal-qa` still prefers a project's own
# node_modules, and then core's, when either exists — so a theme that installs
# custom ESLint plugins is never overridden by this.
#
# ESLint is pinned to the 8.x line on purpose: Drupal core still ships .eslintrc
# files, and ESLint 9 only reads flat config. Using 9 here would silently ignore
# core's rules.
{
  buildNpmPackage,
  nodejs,
  lib,
}:

buildNpmPackage {
  pname = "drupal-qa-node-toolbox";
  version = "0.1.0";
  src = ../toolbox/node;

  # Refresh with: nix build .#nodeToolbox --rebuild
  npmDepsHash = "sha256-rz+PFgrWSErtFIxOqA48/+NyT/Ji4xJ/tNw9APgXDxQ=";

  inherit nodejs;

  # There is nothing to compile; this package exists only to materialise
  # node_modules and its .bin shims in the store.
  dontNpmBuild = true;
  dontNpmInstall = true;
  npmFlags = [ "--ignore-scripts" ];

  # The default install hook packs the project as a publishable npm package,
  # which is the wrong shape here: what the CLI needs is a plain node_modules
  # tree at a predictable path, with .bin alongside it so ESLint and Stylelint
  # resolve their plugins the way they do inside a project.
  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r node_modules $out/node_modules
    cp package.json $out/package.json
    ln -s $out/node_modules/.bin $out/bin

    runHook postInstall
  '';

  meta = {
    description = "Pinned ESLint/Stylelint/Prettier/CSpell toolchain for Drupal QA";
    license = lib.licenses.gpl2Plus;
    platforms = lib.platforms.unix;
  };
}
