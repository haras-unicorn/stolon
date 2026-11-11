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
  `options`, declares every `stolon.*` option and imports the disko and
  impermanence modules. The others only read the options, and a single
  `stolon.enable` turns them all on.
- `src/nix/lib/layout.nix` registers `self.lib.layout`, with its unit tests: the
  names, what is kept, who owns it and the `disko.devices` that the modules, the
  backup tools and the tests must agree on. Derived values and any logic worth a
  test live here as functions and not as internal options or in the modules.
  `nushell.nix` registers `self.lib.nushell`, which writes the scripts.
- Scripts are nushell, written with the haraspkgs `writeNushellApplication`. A
  long one is a mustache template next to its module, in a folder named after
  the module, and `self.lib.nushell` renders it. The exceptions are code that
  other tools paste into their own bash scripts or run in the initrd, each with
  a comment that says why. Test scripts are Python.
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

## Releases

Conventional commits on `main`. Release-please opens a release pull request, and
merging it tags the release and creates the GitHub release. It needs the
`RELEASE_PLEASE_TOKEN` secret.
