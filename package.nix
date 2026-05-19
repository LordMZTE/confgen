{ stdenv
, zig_0_16
, pkg-config
, fuse3
, luajit
, ...
}:
let
  pname = "confgen";
  version = "0.8.2";
  src = ./.;
  deps = zig_0_16.fetchDeps {
    inherit pname version src;
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };
in
stdenv.mkDerivation {
  inherit pname version src;

  nativeBuildInputs = [
    zig_0_16
    pkg-config
  ];

  buildInputs = [
    fuse3
    luajit
  ];

  preBuild = ''
    ln -sf "${deps}" "$ZIG_GLOBAL_CACHE_DIR/p"
  '';
}

