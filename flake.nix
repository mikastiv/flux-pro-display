{
  description = "zig flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    zig-flake.url = "github:silversquirl/zig-flake";
    zig-flake.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      zig-flake,
    }:
    let
      forAllSystems =
        f:
        builtins.mapAttrs (
          system: pkgs: f pkgs zig-flake.packages.${system}.zig_0_16_0
        ) nixpkgs.legacyPackages;
    in
    {
      devShells = forAllSystems (
        pkgs: zig: {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              libusb1
              pciutils
            ];
            nativeBuildInputs = [
              zig
              zig.zls
            ];

            shellHook = ''
              export LD_LIBRARY_PATH="${pkgs.pciutils}/lib:$LD_LIBRARY_PATH"
            '';
          };
        }
      );
    };
}
