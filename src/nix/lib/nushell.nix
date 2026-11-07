{ inputs, ... }:

{
  # Writes a Nushell script from a mustache template, with `vars` rendered into
  # it. The haraspkgs overlays are applied to the given package set, and not
  # through `nixpkgs.overlays`, because NixOS tests do not allow overlays on
  # their machines.
  self.lib.nushell.writeApplication =
    pkgs:
    {
      name,
      template,
      vars ? { },
      runtimeInputs ? [ ],
    }:
    let
      harasPackages = (pkgs.extend inputs.haraspkgs.overlays.default).harasPackages;

      text = harasPackages.renderMustacheText {
        inherit name vars;
        text = builtins.readFile template;
      };
    in
    harasPackages.writeNushellApplication {
      inherit name runtimeInputs text;
    };
}
