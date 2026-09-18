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
      lib = nixpkgs.lib;
      fs = lib.fileset;
      forAllSystems =
        f:
        builtins.mapAttrs (
          system: pkgs: f system pkgs zig-flake.packages.${system}.zig_0_16_0
        ) nixpkgs.legacyPackages;
    in
    {
      devShells = forAllSystems (
        system: pkgs: zig: {
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

      packages = forAllSystems (
        system: pkgs: zig: {
          default = pkgs.stdenv.mkDerivation {
            pname = "flux-pro-display";
            version = "0.1.0";
            meta.mainProgram = "flux-pro-display";
            src = fs.toSource {
              root = ./.;
              fileset = fs.intersection (fs.fromSource (lib.sources.cleanSource ./.)) (
                fs.unions [
                  ./src
                  ./build.zig
                  ./build.zig.zon
                ]
              );
            };

            buildInputs = with pkgs; [
              libusb1
              pciutils
              musl
            ];
            nativeBuildInputs = [
              zig
              pkgs.autoPatchelfHook
            ];
            dontInstall = true;

            configurePhase = ''
              export ZIG_GLOBAL_CACHE_DIR=$TEMP/.cache
            '';

            buildPhase = ''
              zig build install -Doptimize=ReleaseSafe --color off --prefix $out
            '';
          };
        }
      );

      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.services.flux-pro-display;
          package = self.packages.${pkgs.stdenv.hostPlatform.system}.default;

          configFile = pkgs.writeText "flux-pro-display.conf" ''
            cpu_vid ${toString cfg.cpu_vid}
            cpu_pid ${toString cfg.cpu_pid}
            gpu_vid ${toString cfg.gpu_vid}
            gpu_pid ${toString cfg.gpu_pid}
          '';
        in
        {
          options.services.flux-pro-display = {
            enable = lib.mkEnableOption "Flux Pro Display";

            cpu_vid = lib.mkOption {
              type = lib.types.ints.unsigned;
              description = "CPU PCI vendor ID.";
            };

            cpu_pid = lib.mkOption {
              type = lib.types.ints.unsigned;
              description = "CPU PCI product ID.";
            };

            gpu_vid = lib.mkOption {
              type = lib.types.ints.unsigned;
              description = "GPU PCI vendor ID.";
            };

            gpu_pid = lib.mkOption {
              type = lib.types.ints.unsigned;
              description = "GPU PCI product ID.";
            };

          };

          config = lib.mkIf cfg.enable {
            environment.systemPackages = [ package ];
            environment.etc."flux-pro-display/config".source = configFile;

            systemd.services.flux-pro-display = {
              description = "Antec Flux Pro Display Service";
              wantedBy = [ "multi-user.target" ];
              startLimitIntervalSec = 0;

              serviceConfig = {
                Type = "simple";
                ExecStart = "${package}/bin/flux-pro-display";
                Restart = "always";
                RestartSec = 5;
                ProtectSystem = "strict";
                ProtectHome = false;
                PrivateTmp = true;
                NoNewPrivileges = true;
              };
            };
          };
        };
    };
}
