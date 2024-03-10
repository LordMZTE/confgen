{
  description = "Config file template engine";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    utils.url = "github:numtide/flake-utils";
    zig.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, nixpkgs, utils, zig }: utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs { inherit system; };
      deps = pkgs.linkFarm "zig-packages" [
        # zig-args
        {
          name = "12203ded54c85878eea7f12744066dcb4397177395ac49a7b2aa365bf6047b623829";
          path = pkgs.fetchgit {
            url = "https://git.mzte.de/mirrors/zig-args.git";
            rev = "89f18a104d9c13763b90e97d6b4ce133da8a3e2b";
            hash = "sha256-JY0UDJSKOh1Cg46/GnhVTNmgr6TJKoHXgt8FponPCPM=";
          };
        }
      ];
    in
    {
      packages.default = pkgs.stdenv.mkDerivation {
        name = "confgen";
        src = ./.;
        dontConfigure = true;
        dontBuild = true;
        dontFixup = true;

        nativeBuildInputs = with pkgs; [
          pkg-config
          luajit
          fuse3
        ];

        postPatch = ''
          export ZIG_LOCAL_CACHE_DIR=$(pwd)/zig-cache
          export ZIG_GLOBAL_CACHE_DIR=$ZIG_LOCAL_CACHE_DIR
          export NIX_CFLAGS_COMPILE=
          export NIX_LDFLAGS=
          mkdir -p $ZIG_GLOBAL_CACHE_DIR
          ln -s ${deps} $ZIG_GLOBAL_CACHE_DIR/p
        '';
        installPhase = ''
          runHook preBuild
          ${zig.packages.${system}.master}/bin/zig build install --prefix $out
          runHook postBuild
        '';
      };
    });
}
