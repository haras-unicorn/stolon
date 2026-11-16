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
        layout = selfLib.layout;

        harasPackages = (pkgs.extend inputs.haraspkgs.overlays.default).harasPackages;

        rootDevice = config.fileSystems."/".device;

        rootDeviceUnit = "${utils.escapeSystemdPath rootDevice}.device";

        btrfs = lib.getExe pkgs.btrfs-progs;

        chattr = lib.getExe' pkgs.e2fsprogs "chattr";

        wipeRoot = harasPackages.renderMustacheText {
          name = "stolon-wipe-root";
          text = builtins.readFile ./wipe-root.sh;
          vars = {
            inherit rootDevice btrfs;
            rootSubvolume = layout.names.root;
          };
        };

        # Lines of tab-separated fields and not JSON: the initrd has no JSON
        # parser, and a kept path never holds a tab or a newline.
        lines = lib.concatMapStringsSep "\n" (lib.concatStringsSep "\t");

        volumes = lines (
          builtins.map (volume: [
            volume.name
            volume.holder
            volume.within
            (lib.boolToString volume.noCow)
          ]) (layout.creation config.stolon.keep)
        );

        files = lines (
          builtins.map (file: [
            file.path
            file.holder
            file.within
          ]) (layout.fileCreation config.stolon.keep)
        );

        createVolumes = harasPackages.renderMustacheText {
          name = "stolon-create-volumes";
          text = builtins.readFile ./create-volumes.sh;
          vars = {
            inherit
              rootDevice
              btrfs
              chattr
              volumes
              files
              ;
            rootSubvolume = layout.names.root;
            persist = layout.names.persist;
            staging = layout.names.staging;
          };
        };
      in
      {
        config = lib.mkIf config.stolon.enable {
          boot.initrd.systemd = {
            enable = true;
            storePaths = [ chattr ];
            services.stolon-create-volumes = {
              description = "Make what newly kept paths need, from the old root";
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
              script = createVolumes;
            };
            services.stolon-wipe-root = {
              description = "Replace the root subvolume with an empty one";
              unitConfig.DefaultDependencies = false;
              serviceConfig.Type = "oneshot";
              wantedBy = [ "initrd.target" ];
              before = [ "sysroot.mount" ];
              # Only once the newly kept paths have what was on the old root, and
              # not at all when that failed, so the old root is still there for
              # the next boot to try again.
              requires = [
                rootDeviceUnit
                "stolon-create-volumes.service"
              ];
              after = [
                rootDeviceUnit
                "local-fs-pre.target"
                "stolon-create-volumes.service"
              ];
              # Bash on purpose, like the volumes above.
              script = wipeRoot;
            };
          };
        };
      };
  };
}
