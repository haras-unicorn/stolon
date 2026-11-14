{ inputs, selfLib, ... }:

{
  # `makeInstaller` makes the installer of the machines of a flake: the
  # `stolon-installer` command, which is a menu without arguments and a command
  # line with them, and an image for a USB stick that opens the menu on start.
  #
  # - `nixosConfigurations` are the machines it can install. Only their names,
  #   systems and disks are built into it, so it lists them offline and can
  #   guess which one a computer is.
  # - `repository` is the source of the flake, usually its `self`. The
  #   installer evaluates the machines from it.
  # - `remoteFlakeRef` is where the newest version of the flake is, for example
  #   `github:alice/machines`. The menu runs the installer from there when it
  #   is asked to update.
  # - `imageModules` are more NixOS modules for the image, for example a driver
  #   for a Wi-Fi stick that the kernel does not support well.
  #
  # It also makes an offline installer and its image for each machine that uses
  # stolon and runs on the system of the package set, in `offlineInstallers`
  # and `offlineImages`. Each carries the built system of its one machine, so
  # it installs it without the flake or a network.
  #
  # `testInstaller` is the same command with made-up machines, drives and
  # network, which changes nothing, for trying out the menu on any computer.
  # `testImage` is the image with it, for trying it out from a USB stick.
  self.overlays.overlays.installer = {
    flake = true;
    value =
      final: _prev:
      let
        # Flakes that apply this overlay do not have to use haraspkgs, so it is
        # applied to the package set here.
        harasPackages = (final.extend inputs.haraspkgs.overlays.default).harasPackages;

        layout = selfLib.layout;

        hostSystem = final.stdenv.hostPlatform.system;

        makeCommand =
          {
            description,
            machines,
            offlineBuilds,
            repository,
            remoteFlakeRef,
            system,
            fake,
          }:
          final.lib.addMetaAttrs { inherit description; } (
            harasPackages.writeNushellApplication {
              name = "stolon-installer";
              runtimeInputs = [
                final.coreutils
                final.curl
                final.gum
                final.nixos-facter
                final.util-linux
              ];
              text = harasPackages.renderMustacheText {
                name = "stolon-installer";
                text = builtins.readFile ./installer.nu;
                vars = {
                  inherit repository remoteFlakeRef system;
                  machines = builtins.toJSON machines;
                  offlineBuilds = builtins.toJSON offlineBuilds;
                  externalMount = "${layout.names.backupMount}/external";
                  hardwareReports = layout.names.hardwareReports;
                  fake = if fake then "1" else "0";
                };
              };
            }
          );

        makeImage =
          { installer, imageModules }:
          let
            image = inputs.nixpkgs.lib.nixosSystem {
              modules = [
                (
                  { modulesPath, ... }:
                  {
                    imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];
                  }
                )
                selfLib.installer.imageModule
                {
                  nixpkgs.hostPlatform = hostSystem;
                  stolon.installer.package = installer;
                }
              ]
              ++ imageModules;
            };
          in
          image.config.system.build.isoImage;

        makeInstaller =
          {
            nixosConfigurations,
            repository,
            remoteFlakeRef,
            imageModules ? [ ],
          }:
          let
            summaries = builtins.mapAttrs (_: selfLib.installer.machineSummary) nixosConfigurations;

            installer = makeCommand {
              description = "Install, back up and restore machines from a live USB";
              machines = summaries;
              offlineBuilds = { };
              repository = "path:${repository}";
              inherit remoteFlakeRef;
              system = hostSystem;
              fake = false;
            };

            # An image boots on one system, so it carries the machines of that
            # system.
            offlineMachines = final.lib.filterAttrs (
              _: summary: summary.disk != null && summary.system == hostSystem
            ) summaries;

            # An offline installer evaluates nothing, so it gets no flake, which
            # would only take room on the USB stick.
            makeOfflineInstaller =
              name:
              makeCommand {
                description = "Install ${name} from a live USB without a network";
                machines.${name} = summaries.${name};
                offlineBuilds = selfLib.installer.offlineBuilds nixosConfigurations.${name};
                repository = "";
                remoteFlakeRef = "";
                system = hostSystem;
                fake = false;
              };

            offlineInstallers = builtins.mapAttrs (name: _: makeOfflineInstaller name) offlineMachines;
          in
          {
            inherit installer offlineInstallers;
            image = makeImage { inherit installer imageModules; };
            offlineImages = builtins.mapAttrs (
              _: offlineInstaller:
              makeImage {
                installer = offlineInstaller;
                inherit imageModules;
              }
            ) offlineInstallers;
          };

        testInstaller = makeCommand {
          description = "The installer with made-up machines and drives, for trying out the menu";
          inherit (selfLib.installer.fakes) machines system;
          offlineBuilds = { };
          repository = "github:example/machines";
          remoteFlakeRef = "github:example/machines";
          fake = true;
        };

        testImage = makeImage {
          installer = testInstaller;
          imageModules = [ ];
        };
      in
      {
        inherit makeInstaller testInstaller testImage;
      };
  };
}
