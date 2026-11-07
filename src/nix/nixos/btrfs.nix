{
  self.nixosModules.btrfs = {
    flake = true;
    value =
      { config, lib, ... }:
      lib.mkIf config.stolon.enable {
        boot.supportedFilesystems.btrfs = true;
      };
  };
}
