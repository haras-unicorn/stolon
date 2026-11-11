{ inputs, self, ... }:

{
  # The book, which the docs workflow publishes. The haraspkgs overlays are
  # applied on top of the package set, because overlays can only depend on the
  # ones registered in this flake.
  self.overlays.overlays.docs = {
    flake = true;
    value = final: _prev: {
      docs = (final.extend inputs.haraspkgs.overlays.default).harasPackages.mkMdbook {
        name = "stolon-docs";
        src = self.outPath;
      };
    };
  };
}
