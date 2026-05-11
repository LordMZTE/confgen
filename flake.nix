{
  description = "Config file template engine";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self
    , nixpkgs
    , utils
    }: utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs { inherit system; };
    in
    rec {
      packages.default = pkgs.callPackage ./package.nix { };

      devShells.default = pkgs.mkShell {
        buildInputs = packages.default.buildInputs ++ (with pkgs; [ zig_0_16 pkg-config ]);
      };
    });
}
