{
  description = "Drupal code quality tooling and tests, reproducibly, alongside DDEV";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    let
      # PHP versions Drupal 11 supports. CORE_PHP_MIN is the default because it
      # is what contrib CI targets unless a project opts into more, so a clean
      # local run means a clean pipeline.
      phpVersions = {
        "8.3" = "php83";
        "8.4" = "php84";
        "8.5" = "php85";
      };
      defaultPhpVersion = "8.3";
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
        lib = pkgs.lib;

        phpEnvs = lib.mapAttrs (
          _version: attr:
          import ./nix/php-env.nix {
            basePhp = pkgs.${attr};
            inherit lib;
          }
        ) phpVersions;

        defaultPhp = phpEnvs.${defaultPhpVersion};

        phpToolbox = import ./nix/toolbox-php.nix {
          php = defaultPhp;
          inherit lib;
        };

        nodejs = pkgs.nodejs_22;

        nodeToolbox = import ./nix/toolbox-node.nix {
          inherit (pkgs) buildNpmPackage;
          inherit nodejs lib;
        };

        # Everything the CLI shells out to. Keeping this list explicit means the
        # wrapper's PATH is closed: `drupal-qa` behaves the same whether the user
        # has a system PHP, a Homebrew node, or nothing at all.
        runtimeDeps = [
          defaultPhp
          nodejs
          pkgs.php84Packages.composer
          pkgs.bash
          pkgs.coreutils
          pkgs.curl
          pkgs.diffutils
          pkgs.findutils
          pkgs.gawk
          pkgs.git
          pkgs.gnugrep
          pkgs.gnused
          pkgs.jq
          pkgs.ncurses
          pkgs.procps
          pkgs.unzip
          pkgs.which
          pkgs.yq-go
        ];

        # Optional heavier tools. Split out so `drupal-qa doctor` can report them
        # as present-or-absent instead of the CLI failing at the point of use.
        browserDeps = [
          pkgs.chromedriver
          pkgs.chromium
        ];

        ciDeps = [ pkgs.gitlab-ci-local ];

        drupal-qa = pkgs.stdenv.mkDerivation {
          pname = "drupal-qa";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = [
            pkgs.makeWrapper
            pkgs.shellcheck
          ];

          dontConfigure = true;

          buildPhase = ''
            runHook preBuild
            shellcheck --shell=bash --external-sources bin/drupal-qa bin/lib/*.sh
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p $out/bin $out/libexec/drupal-qa
            cp -r bin/lib $out/libexec/drupal-qa/lib
            cp -r assets $out/libexec/drupal-qa/assets
            cp -r templates $out/libexec/drupal-qa/templates
            install -m 0755 bin/drupal-qa $out/libexec/drupal-qa/drupal-qa

            makeWrapper $out/libexec/drupal-qa/drupal-qa $out/bin/drupal-qa \
              --prefix PATH : ${lib.makeBinPath (runtimeDeps ++ browserDeps ++ ciDeps)} \
              --set DRUPAL_QA_LIB $out/libexec/drupal-qa/lib \
              --set DRUPAL_QA_ASSETS $out/libexec/drupal-qa/assets \
              --set DRUPAL_QA_TEMPLATES $out/libexec/drupal-qa/templates \
              --set DRUPAL_QA_PHP_TOOLBOX ${phpToolbox} \
              --set DRUPAL_QA_NODE_TOOLBOX ${nodeToolbox} \
              --set DRUPAL_QA_NODE ${nodejs}/bin/node \
              --set DRUPAL_QA_CHROMEDRIVER ${pkgs.chromedriver}/bin/chromedriver \
              --set DRUPAL_QA_CHROME ${pkgs.chromium}/bin/chromium \
              --set DRUPAL_QA_VERSION 0.1.0 \
              ${
                lib.concatMapStringsSep " " (
                  v: "--set DRUPAL_QA_PHP_${lib.replaceStrings [ "." ] [ "_" ] v} ${phpEnvs.${v}}/bin/php"
                ) (lib.attrNames phpVersions)
              } \
              --set DRUPAL_QA_PHP_DEFAULT ${defaultPhpVersion}

            runHook postInstall
          '';

          meta = {
            description = "Run Drupal's CI code quality tools and tests locally";
            mainProgram = "drupal-qa";
            license = lib.licenses.gpl2Plus;
            platforms = lib.platforms.unix;
          };
        };
      in
      {
        packages = {
          inherit drupal-qa phpToolbox nodeToolbox;
          default = drupal-qa;
        }
        // lib.mapAttrs' (v: p: lib.nameValuePair "php-${lib.replaceStrings [ "." ] [ "_" ] v}" p) phpEnvs;

        apps.default = {
          type = "app";
          program = "${drupal-qa}/bin/drupal-qa";
        };

        devShells.default = pkgs.mkShell {
          name = "drupal-qa";
          packages = [ drupal-qa ] ++ runtimeDeps ++ browserDeps ++ ciDeps ++ [ pkgs.shellcheck ];

          shellHook = ''
            echo "drupal-qa $DRUPAL_QA_VERSION  ·  php $(php -r 'echo PHP_VERSION;')  ·  node $(node --version)"
            echo "Try: drupal-qa info   |   drupal-qa lint <path-or-module>   |   drupal-qa --help"
          '';
        };

        checks = {
          # Proves the CLI parses, the toolboxes resolve, and the assets landed.
          smoke = pkgs.runCommand "drupal-qa-smoke" { nativeBuildInputs = [ drupal-qa ]; } ''
            drupal-qa --version
            drupal-qa --help > /dev/null
            drupal-qa doctor --offline
            touch $out
          '';
        };

        formatter = pkgs.nixfmt-tree;
      }
    )
    // {
      overlays.default = final: prev: {
        drupal-qa = self.packages.${final.system}.drupal-qa;
      };

      templates = {
        contrib = {
          path = ./templates/contrib;
          description = "Drupal contrib module/theme with pinned QA tooling and GitLab CI";
        };
        default = self.templates.contrib;
      };
    };
}
