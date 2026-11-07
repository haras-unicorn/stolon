{ selfLib, ... }:

{
  self.nixosTests.gc = {
    flake = true;
    value =
      _:
      let
        roots = "/nix/var/nix/gcroots/auto";

        # Makes a git project with a direnv gcroot, whose HEAD last moved at
        # the given date. The gcroot points at a real store path, because Nix
        # ignores roots that do not.
        project = name: date: ''
          machine.succeed("""
            mkdir -p /projects/${name}/.direnv
            cd /projects/${name}
            git init --quiet
            GIT_AUTHOR_DATE='${date}' GIT_COMMITTER_DATE='${date}' \
              git -c user.name=test -c user.email=test@test commit --quiet --allow-empty -m init
            ln -s "$(readlink /run/current-system)" .direnv/flake-profile-${name}
            ln -s /projects/${name}/.direnv/flake-profile-${name} ${roots}/${name}
          """)
        '';
      in
      {
        globalTimeout = selfLib.tests.globalTimeout;

        nodes.machine =
          { pkgs, ... }:
          {
            # Only the options and the gc modules, because the rest would take
            # over the test machine's disk.
            imports = [
              selfLib.nixosModules.options
              selfLib.nixosModules.nix-gc
              selfLib.nixosModules.direnv
            ];

            stolon.enable = true;
            stolon.gc.retentionDays = 7;
            environment.systemPackages = [ pkgs.git ];
          };

        testScript = ''
          machine.wait_for_unit("multi-user.target")
          machine.succeed("mkdir -p ${roots}")

          ${project "stale" "2020-01-01T00:00:00"}
          ${project "fresh" "2099-01-01T00:00:00"}
          machine.succeed("ln -s \"$(readlink /run/current-system)\" ${roots}/unrelated")

          machine.succeed("systemctl start stolon-direnv-gcroots.service")

          with subtest("the gcroot of an inactive project is removed"):
              machine.fail("test -L /projects/stale/.direnv/flake-profile-stale")
              # Nix drops the link it kept to it on its next scan, as the
              # collection does.
              machine.succeed("nix-store --gc --print-roots")
              machine.fail("test -L ${roots}/stale")

          with subtest("the gcroot of an active project and other gcroots stay"):
              machine.succeed("test -L ${roots}/fresh")
              machine.succeed("test -L ${roots}/unrelated")

          with subtest("the collection waits for the cleanup"):
              machine.succeed("systemctl show nix-gc.service --property=After | grep -q stolon-direnv-gcroots")
        '';
      };
  };
}
