{ pkgs, ... }:
pkgs.linkFarm "zig-packages" [
  # zig-args
  {
    name = "args-0.0.0-CiLiqojRAACGzDRO7A9dw7kWSchNk29caJZkXuMCb0Cn";
    path = pkgs.fetchgit {
      url = "https://git.mzte.de/mirrors/zig-args.git";
      rev = "8ae26b44a884ff20dca98ee84c098e8f8e94902f";
      hash = "sha256-LfUIqbHNS6DPvLV68Jxsz7OKJ9+y3ZOuvlja9whe9Wo=";
    };
  }
]
