{ pkgs, ... }:
pkgs.linkFarm "zig-packages" [
  # zig-args
  {
    name = "1220fe6ae56b668cc4a033282b5f227bfbb46a67ede6d84e9f9493fea9de339b5f37";
    path = pkgs.fetchgit {
      url = "https://git.mzte.de/mirrors/zig-args.git";
      rev = "872272205d95bdba33798c94e72c5387a31bc806";
      hash = "sha256-H/sT6JHun+jR37fJSbsauE9K3igV/frcnD/w4Pngzc4=";
    };
  }
]
