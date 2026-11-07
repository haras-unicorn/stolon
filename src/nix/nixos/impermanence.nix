{ selfLib, ... }:

{
  self.nixosModules.impermanence = {
    flake = true;
    value =
      { config, lib, ... }:
      let
        cfg = config.stolon;

        layout = selfLib.layout;

        wanted = layout.kept cfg.keep;

        homes = layout.homes config.users.users;

        persistence = layout.persistence { inherit wanted homes; };
      in
      lib.mkIf cfg.enable {
        assertions = [
          {
            assertion = !(layout.volumesCollide cfg.keep);
            message = "stolon: two kept directories map to the same subvolume name.";
          }
        ];

        environment.persistence.${layout.names.persistMount} = {
          hideMounts = true;
          inherit (persistence) directories files;
        };

        systemd.tmpfiles.rules = layout.tmpfiles { inherit wanted homes; };
      };
  };
}
