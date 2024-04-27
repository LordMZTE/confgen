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
      deps = pkgs.callPackage ./deps.nix { };
    in
    {
      packages.default = pkgs.stdenv.mkDerivation {
        name = "confgen";
        src = ./.;

        dontConfigure = true;

        nativeBuildInputs = with pkgs; [
          zig_0_12.hook
          pkg-config
          luajit
          fuse3
        ];

        buildInputs = with pkgs; [
          luajit
          fuse3
        ];

        postPatch = ''
          ln -sf "${deps}" "$ZIG_GLOBAL_CACHE_DIR/p"
        '';
      };
    });
}
