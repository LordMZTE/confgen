{ pkgs, ... }:
pkgs.linkFarm "zig-packages" [
  # zig-args
  {
    name = "12203ded54c85878eea7f12744066dcb4397177395ac49a7b2aa365bf6047b623829";
    path = pkgs.fetchgit {
      url = "https://git.mzte.de/mirrors/zig-args.git";
      rev = "89f18a104d9c13763b90e97d6b4ce133da8a3e2b";
      hash = "sha256-JY0UDJSKOh1Cg46/GnhVTNmgr6TJKoHXgt8FponPCPM=";
    };
  }
]
