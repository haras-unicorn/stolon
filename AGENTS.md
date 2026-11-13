# Stolon

NixOS modules that put a whole system on one disk: btrfs, encrypted and
compressed, with an impermanent root, backups and garbage collection. The
`README.md` holds the invariants and decisions the code is held to.

## Structure

A Nix flake built on haraspkgs. All Nix is under `src/nix`, and every file there
is a flake-parts module. The only import is `flake.nix` pointing at `src/nix`,
and haraspkgs builds `nixosModules.default` from the rest.

- `src/nix/nixos/` registers one `self.nixosModules` entry per file, named after
  the program it configures (for example `grub`, `btrfs`, `restic`). One file,
  `options`, declares every `stolon.*` option of a machine and imports the disko
  and impermanence modules. The others only read the options, and a single
  `stolon.enable` turns them all on.
- `src/nix/lib/layout.nix` registers `self.lib.layout`, with its unit tests: the
  names, what is kept, who owns it and the `disko.devices` that the modules, the
  backup tools and the tests must agree on. Derived values and any logic worth a
  test live here as functions and not as internal options or in the modules.
- `src/nix/lib/installer.nix` registers `self.lib.installer`: the summary the
  installer keeps of each machine, what an offline installer carries of its
  machine, and the NixOS module of the installer image, which the image and the
  installer test share. That module declares its own `stolon.installer.package`,
  so machines do not carry it.
- Anything that takes a package set is an overlay in `src/nix/overlays/`, under
  the `stolonPackages` namespace, and not a `self.lib` function. haraspkgs puts
  them on the `pkgs` of the flake and the dev shell, and NixOS modules apply the
  one they need with `pkgs.extend`. `installer` (exported) gives `makeInstaller`
  and the `testInstaller` and `testImage` packages, and `docs` the book. The dev
  shell renders the options page with the haraspkgs `mkOptionsDocs`.
- Scripts are nushell, written with the haraspkgs `writeNushellApplication`. A
  long one is a mustache template next to its module, in a folder named after
  the module, rendered with the haraspkgs `renderMustacheText`. The exceptions
  are code that other tools paste into their own bash scripts or run in the
  initrd, each with a comment that says why. Test scripts are Python.
- `src/nix/overlays/installer/` is the installer: one Nushell script that is a
  command line with subcommands and, without them, a gum menu that only asks and
  calls those subcommands, so all the logic is in what the tests run. Its TUI,
  CLI and EXT sections hold the menu, the commands with their logic, and
  everything that touches the computer. `STOLON_INSTALLER_DRY_RUN` and
  `STOLON_INSTALLER_FAKE` skip or fake what is in EXT, and `testInstaller` fakes
  by default, with the machines of `self.lib.installer.fakes`. `testImage` is
  the image with `testInstaller`.
- `src/nix/tests/` holds the integration tests, which are NixOS VM tests. Boot
  tests go through the disko test library. Everything else goes through
  `self.nixosTests`.
- `src/nix/dev/shell.nix` is the dev shell, `src/nix/systems.nix` the supported
  systems.
- `docs/` is the mdbook. Its introduction includes parts of the `README.md`, and
  `docs/src/options.md` is generated from the options by the dev shell, so edit
  `options.nix` and not the page. `src/nix/overlays/docs.nix` builds the book as
  the `docs` package, which the docs workflow publishes to GitHub Pages.

## Development

The dev shell comes from the flake and is loaded by direnv. `dev check` and
`dev format` run the checks and the formatters, and `nix flake check` runs those
and the tests.

Everything that haraspkgs generates is committed but owned by the dev shell:
`.gitignore`, `.gitattributes`, `LICENSE.md`, `CODE_OF_CONDUCT.md`,
`.github/workflows/` and `docs/src/options.md`. Change `dev/shell.nix` and enter
the shell again, not the files. The release-please files are written by hand.

## Testing

Every scenario the README promises is a VM test, because disks cannot be tested
any other way. `haraspkgs` calls `self.nixosTests` container tests, but it
passes the module to `runNixOSTest` untouched, so `nodes` and QEMU disks work.

The boot tests run on x86 only, since disko's boot tests hang on aarch64. CI
runs everything on x86 and only evaluates on ARM.

The installer test boots the image's module and gives the virtual machine a
small flake that points at this one, with every flake source, the built machine
and what renders the mustache templates in its store, so the installer evaluates
and installs the machine offline. The machine is
`self.lib.tests.installerMachine`, so the host and the virtual machine build the
same system. The offline installer test boots the same module with the offline
installer of that machine, and without a network, substituters or flake sources.

## Releases

Conventional commits on `main`. Release-please opens a release pull request, and
merging it tags the release and creates the GitHub release. It needs the
`RELEASE_PLEASE_TOKEN` secret.
