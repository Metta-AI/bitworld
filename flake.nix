{
  description = "Bitworld dev environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      nimbyRelease = {
        x86_64-linux   = { suffix = "Linux-X64";   hash = "sha256-jh5cJ2nGV/WZ+xXcTu8b2GHN7omMYpPSpi3zAML2VMU="; };
        aarch64-linux  = { suffix = "Linux-ARM64"; hash = "sha256-MJWc9sCCZlS3jC2RgNOQspma0/wtXX5pt4AoUZ7kjKk="; };
        aarch64-darwin = { suffix = "macOS-ARM64"; hash = "sha256-JDGFj9jjksALrvvrHOwaFzR3V1lBRkFHU5gzyLm2sCw="; };
      };
    in
    flake-utils.lib.eachSystem (builtins.attrNames nimbyRelease) (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        isLinux = pkgs.lib.hasSuffix "linux" system;
        nimbyInfo = nimbyRelease.${system};

        nimby = pkgs.stdenv.mkDerivation {
          pname = "nimby";
          version = "0.1.26";
          src = pkgs.fetchurl {
            url = "https://github.com/treeform/nimby/releases/download/0.1.26/nimby-${nimbyInfo.suffix}";
            hash = nimbyInfo.hash;
          };
          nativeBuildInputs = pkgs.lib.optionals isLinux [ pkgs.autoPatchelfHook ];
          buildInputs = pkgs.lib.optionals isLinux [ pkgs.glibc ];
          dontUnpack = true;
          installPhase = "install -D $src $out/bin/nimby";
        };

        # Runtime libs that windy / pixie / opengl dlopen. Made available
        # both at link time (LIBRARY_PATH) and at runtime (LD_LIBRARY_PATH)
        # so the built game/client binaries can find libX11, libGL, etc.
        runtimeLibs = with pkgs; [
          libx11
          libxcursor
          libxrandr
          libxi
          libxinerama
          libxext
          libxrender
          libxxf86vm
          libGL
          libGLU
          fontconfig
          freetype
          udev    # paddy gamepad input on linux
          libevdev
        ];
      in {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            nim
            nimble
            nimby
            git
            pkg-config
          ] ++ runtimeLibs;

          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath runtimeLibs;
          LIBRARY_PATH = pkgs.lib.makeLibraryPath runtimeLibs;

          shellHook = ''
            # Sync vendored Nim deps into ./.nimby/<name>/ at the commits
            # pinned in nimby.lock. We treat .nimby/ as a nimby workspace
            # so the auto-generated .nimby/nim.cfg has paths relative to
            # itself; config.nims forwards those into nim's search path.
            if [[ -f nimby.lock ]]; then
              mkdir -p .nimby
              ( cd .nimby && nimby sync ../nimby.lock ) \
                || echo "warning: nimby sync failed"
            fi
            echo "Bitworld dev environment ready"
            echo "  nim:    $(nim --version 2>/dev/null | head -1)"
            echo "  nimble: $(nimble --version 2>/dev/null | head -1)"
            echo "  nimby:  $(nimby --version 2>/dev/null | head -1)"
          '';
        };
      }
    );
}
