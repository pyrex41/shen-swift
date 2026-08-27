{
  description = "shen-swift development environment";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  outputs = { nixpkgs, ... }: let systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ]; each = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system}); available = pkgs: builtins.filter (p: pkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform p) [ pkgs.swift ]; in {
    packages = each (pkgs: { toolchain = pkgs.buildEnv { name = "shen-swift-toolchain"; paths = available pkgs; }; default = pkgs.buildEnv { name = "shen-swift-toolchain"; paths = available pkgs; }; });
    devShells = each (pkgs: { default = pkgs.mkShell { packages = available pkgs; }; });
  };
}
