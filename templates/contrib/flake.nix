{
  description = "Drupal project with pinned code quality tooling";

  inputs = {
    # Everything — PHP, Node, PHPCS, PHPStan, ESLint, chromedriver — comes from
    # here. Pin it to a tag or commit to freeze your whole QA toolchain.
    drupal-nix-tools.url = "github:your-org/drupal-nix-tools";
  };

  outputs =
    { drupal-nix-tools, ... }:
    let
      forAllSystems =
        f:
        builtins.listToAttrs (
          map
            (system: {
              name = system;
              value = f system;
            })
            [
              "x86_64-linux"
              "aarch64-linux"
              "x86_64-darwin"
              "aarch64-darwin"
            ]
        );
    in
    {
      devShells = forAllSystems (system: {
        default = drupal-nix-tools.devShells.${system}.default;
      });

      # `nix run .#qa -- lint` without entering the shell first.
      packages = forAllSystems (system: {
        default = drupal-nix-tools.packages.${system}.drupal-qa;
      });
    };
}
