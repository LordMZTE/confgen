{
  description = "Config file template engine";

  inputs = {
    # TODO: use unstable once zig 0.14 lands there
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
      deps = pkgs.callPackage ./deps.nix { };
    in
    rec {
      packages.default = pkgs.stdenv.mkDerivation {
        name = "confgen";
        src = ./.;

        dontConfigure = true;

        nativeBuildInputs = with pkgs; [
          zig_0_14.hook
          pkg-config
        ];

        buildInputs = with pkgs; [
          luajit
          fuse3
        ];

        postPatch = ''
          ln -sf "${deps}" "$ZIG_GLOBAL_CACHE_DIR/p"
        '';
      };

      devShells.default = pkgs.mkShell {
        buildInputs = packages.default.buildInputs ++ (with pkgs; [ pkg-config ]);
      };
    });
}
