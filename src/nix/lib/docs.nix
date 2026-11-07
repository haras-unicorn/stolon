{ inputs, selfLib, ... }:

{
  # The `stolon` options rendered as CommonMark. The module also pulls in the
  # disko and impermanence modules, which are documented by their own projects,
  # so only the options under `stolon` are kept. They set NixOS options that a
  # bare module evaluation does not declare, so that check is off.
  self.lib.docs.options =
    pkgs:
    let
      harasPackages = (pkgs.extend inputs.haraspkgs.overlays.default).harasPackages;

      keepStolon =
        option:
        option
        // {
          visible = option.visible && builtins.head option.loc == "stolon";
          declarations = [ ];
        };
    in
    (harasPackages.mkOptionsDocs {
      modules = [
        { _module.check = false; }
        selfLib.nixosModules.options
      ];
      specialArgs = { inherit pkgs; };
      transformOptions = keepStolon;
    }).optionsCommonMark;
}
