{
  self.nixosModules.nix-gc = {
    flake = true;
    value =
      { config, lib, ... }:
      let
        cfg = config.stolon.gc;
      in
      lib.mkIf (config.stolon.enable && cfg.enable) {
        nix.gc = {
          automatic = true;
          dates = "daily";
          persistent = true;
          options = "--delete-older-than ${toString cfg.retentionDays}d";
        };

        # Wants and after, so the collection runs once the stale roots are
        # gone, and still runs when the cleanup fails.
        systemd.services.nix-gc = {
          wants = [ "stolon-direnv-gcroots.service" ];
          after = [ "stolon-direnv-gcroots.service" ];
        };
      };
  };
}
