{
  self.nixosModules.grub = {
    flake = true;
    value =
      { config, lib, ... }:
      lib.mkIf config.stolon.enable {
        boot.loader.efi.canTouchEfiVariables = lib.mkDefault false;
        boot.loader.grub = {
          # Beats the default priority of the systemd-boot module's
          # `enable = false`, and still loses to a plain definition.
          enable = lib.mkOverride 900 true;
          device = lib.mkDefault "nodev";
          efiSupport = lib.mkDefault true;
          useOSProber = lib.mkDefault true;
          efiInstallAsRemovable = lib.mkDefault true;
        };
      };
  };
}
