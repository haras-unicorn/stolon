{
  self.nixosModules.fstrim = {
    flake = true;
    value =
      { config, lib, ... }:
      lib.mkIf config.stolon.enable {
        services.fstrim.enable = config.stolon.trim.enable;
      };
  };
}
