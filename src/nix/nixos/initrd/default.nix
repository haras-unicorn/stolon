{ inputs, selfLib, ... }:

{
  self.nixosModules.initrd = {
    flake = true;
    value =
      {
        config,
        lib,
        pkgs,
        utils,
        ...
      }:
      let
        rootDevice = config.fileSystems."/".device;

        rootDeviceUnit = "${utils.escapeSystemdPath rootDevice}.device";

        wipeRoot = (pkgs.extend inputs.haraspkgs.overlays.default).harasPackages.renderMustacheText {
          name = "stolon-wipe-root";
          text = builtins.readFile ./wipe-root.sh;
          vars = {
            inherit rootDevice;
            rootSubvolume = selfLib.layout.names.root;
            btrfs = lib.getExe pkgs.btrfs-progs;
          };
        };
      in
      {
        config = lib.mkIf config.stolon.enable {
          boot.initrd.systemd = {
            enable = true;
            services.stolon-wipe-root = {
              description = "Replace the root subvolume with an empty one";
              unitConfig.DefaultDependencies = false;
              serviceConfig.Type = "oneshot";
              wantedBy = [ "initrd.target" ];
              before = [ "sysroot.mount" ];
              requires = [ rootDeviceUnit ];
              after = [
                rootDeviceUnit
                "local-fs-pre.target"
              ];
              # Bash on purpose: the initrd already has it, and nushell would add
              # its whole closure to the initrd that is read on every boot.
              script = wipeRoot;
            };
          };
        };
      };
  };
}
