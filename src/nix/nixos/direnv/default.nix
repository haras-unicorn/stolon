{ inputs, ... }:

{
  self.nixosModules.direnv = {
    flake = true;
    value =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      let
        cfg = config.stolon.gc;

        # NixOS tests do not allow overlays on their machines, so haraspkgs is
        # applied to the package set here and not through `nixpkgs.overlays`.
        harasPackages = (pkgs.extend inputs.haraspkgs.overlays.default).harasPackages;

        cleanup = harasPackages.writeNushellApplication {
          name = "stolon-direnv-gcroots";
          runtimeInputs = [
            pkgs.git
            config.nix.package
          ];
          text = harasPackages.renderMustacheText {
            name = "stolon-direnv-gcroots";
            text = builtins.readFile ./cleanup.nu;
            vars.retentionDays = builtins.toJSON cfg.retentionDays;
          };
        };
      in
      {
        config = lib.mkIf (config.stolon.enable && cfg.enable) {
          systemd.services.stolon-direnv-gcroots = {
            description = "Remove the gcroots of inactive direnv projects";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = lib.getExe cleanup;
            };
          };
        };
      };
  };
}
