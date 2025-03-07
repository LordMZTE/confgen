{ pkgs, ... }:
pkgs.linkFarm "zig-packages" [
  # zig-args
  {
    name = "args-0.0.0-CiLiqv_NAAC97fGpk9hS2K681jkiqPsWP6w3ucb_ctGH";
    path = pkgs.fetchgit {
      url = "https://git.mzte.de/mirrors/zig-args.git";
      rev = "9425b94c103a031777fdd272c555ce93a7dea581";
      hash = "sha256-hlt4URhSb6g8y9hrR1gJ6Jw8rVbLXW50/iITzL0Vxgc=";
    };
  }
]
