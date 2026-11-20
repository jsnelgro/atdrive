# Nix: the `atdrive` command line tool, and a shell with everything needed to build and test it.
#
#   nix run .# -- --help         # run atdrive
#   nix build .#                 # build it (result/bin/atdrive)
#   nix develop                  # a shell with Swift, then: scripts/test.sh, swift build, ...
#
# Linux only: on a Mac, use Xcode's Swift (the app needs it anyway). Swift comes from nixpkgs
# (6.4.0), which builds and tests ATDrive but can't make the static release binaries: its compiler
# always adds Nix's glibc headers, which breaks the musl build. Those come from
# scripts/build-static.sh with a swift.org toolchain, or the swift:6.4.x container.
{
  description = "ATDrive: a Dropbox-style drive stored in atproto spaces";

  # Git rather than github:, which needs GitHub's API. A shallow clone of one commit is quick.
  inputs.nixpkgs.url = "git+https://github.com/NixOS/nixpkgs?ref=nixos-unstable&shallow=1";

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # The version is written down once, in Version.swift.
      version = lib.pipe ./Sources/ATDriveCore/Version.swift [
        builtins.readFile
        (lib.splitString "\n")
        (map (builtins.match ''.*public static let current = "([^"]+)".*''))
        (lib.findFirst (m: m != null) (throw "flake.nix: no version in Version.swift"))
        builtins.head
      ];

      # Just what the build reads, so editing docs or scripts doesn't rebuild it. (Package.swift
      # declares the test target, so SwiftPM wants Tests/ even when it doesn't build it.)
      src = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          ./Package.swift
          ./Package.resolved
          ./Sources
          ./Tests
        ];
      };
    in
    {
      packages = forAllSystems (pkgs: rec {
        atdrive = pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "atdrive";
          inherit version src;

          nativeBuildInputs = [
            pkgs.swift
            pkgs.swiftpm
          ];

          # The packages in Package.resolved, fetched ahead of the (offline) build. When
          # Package.resolved changes, this hash does too: build, and copy the hash Nix prints.
          swiftpmDeps = pkgs.fetchSwiftPMDeps {
            inherit (finalAttrs) src;
            hash = "sha256-rGOVobIGs3aH2CmBRPw/x8m9xKrUtIKQvngE1jE2d24=";
          };
          swiftpmFlags = [
            "--product"
            "atdrive"
          ];

          installPhase = ''
            runHook preInstall
            install -D -m 755 "$(swiftpmBinPath)/atdrive" "$out/bin/atdrive"
            runHook postInstall
          '';

          # The tests run in CI with scripts/test.sh (on a plain and an encrypted drive).
          doCheck = false;

          meta = {
            description = "A Dropbox-style drive stored in atproto spaces";
            homepage = "https://github.com/jsnelgro/atdrive";
            mainProgram = "atdrive";
            platforms = systems;
          };
        });
        default = atdrive;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          # nixpkgs' Swift 6.4.0 crashes (SIGSEGV in _Unwind_Backtrace) when Swift Testing records
          # where a thrown error came from, which fails every suite that throws on purpose. Tests
          # only lose that extra detail in failure reports.
          SWT_SWIFT_ERROR_BACKTRACING_ENABLED = "0";
          packages = [
            pkgs.swift
            pkgs.swiftpm
            pkgs.swiftPackages.swift-testing
            pkgs.swift-format
            pkgs.git
            pkgs.libsecret # secret-tool: where atdrive keeps its session on Linux
          ];
        };
      });

      checks = forAllSystems (pkgs: {
        atdrive = self.packages.${pkgs.stdenv.hostPlatform.system}.atdrive;
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
