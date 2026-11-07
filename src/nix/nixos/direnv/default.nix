{ selfLib, ... }:

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

        cleanup = selfLib.nushell.writeApplication pkgs {
          name = "stolon-direnv-gcroots";
          runtimeInputs = [
            pkgs.git
            config.nix.package
          ];
          template = ./cleanup.nu;
          vars.retentionDays = builtins.toJSON cfg.retentionDays;
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
