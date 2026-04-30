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

      # Mirrors the bin = @[...] list in bitworld.nimble. Update both together.
      bitworldBins = [
        "clients/global_client"
        "clients/player_client"
        "clients/reward_client"
        "asteroid_arena/asteroid_arena"
        "big_adventure/big_adventure"
        # "big_adventure/player"  # Currently broken: imports big_adventure/server which shadows common/server, hiding Sprite.
        "brushwalk/brushwalk"
        "bubble_eats/bubble_eats"
        "free_chat/free_chat"
        "fancy_cookout/fancy_cookout"
        "ice_brawl/ice_brawl"
        "infinite_blocks/infinite_blocks"
        "planet_wars/planet_wars"
        "stag_hunt/stag_hunt"
        "overworld/overworld"
        "tools/quick_run"
        "tools/quick_player"
        "tools/ptswap"
        "tag/tag"
        "jumper/jumper"
        "warzone/warzone"
        "among_them/among_them"
        "global_ui/global_ui"
      ];
    in
    flake-utils.lib.eachSystem (builtins.attrNames nimbyRelease) (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        isLinux = lib.hasSuffix "linux" system;
        nimbyInfo = nimbyRelease.${system};

        nimby = pkgs.stdenv.mkDerivation {
          pname = "nimby";
          version = "0.1.26";
          src = pkgs.fetchurl {
            url = "https://github.com/treeform/nimby/releases/download/0.1.26/nimby-${nimbyInfo.suffix}";
            hash = nimbyInfo.hash;
          };
          nativeBuildInputs = lib.optionals isLinux [ pkgs.autoPatchelfHook ];
          buildInputs = lib.optionals isLinux [ pkgs.glibc ];
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

        # Fixed-output derivation: runs `nimby sync` to vendor every dep
        # listed in nimby.lock into .nimby/<name>/. Network is allowed
        # because outputHash is set; the hash covers the entire vendored
        # tree, so updating nimby.lock requires updating outputHash too.
        vendoredDeps = pkgs.stdenv.mkDerivation {
          pname = "bitworld-deps";
          version = "0.1.0";
          src = ./nimby.lock;
          dontUnpack = true;
          nativeBuildInputs = [ nimby pkgs.git pkgs.cacert ];
          buildPhase = ''
            export HOME=$TMPDIR
            export GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            mkdir -p workspace
            cp $src workspace/nimby.lock
            mkdir workspace/.nimby
            (cd workspace/.nimby && nimby sync ../nimby.lock)
            # Drop .git dirs so the output hash is content-deterministic.
            find workspace/.nimby -name .git -type d -prune -exec rm -rf {} +
          '';
          installPhase = ''
            mkdir -p $out
            cp -r workspace/.nimby/. $out/
          '';
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          # Update this hash whenever nimby.lock changes (Nix will print the
          # expected value on hash mismatch).
          outputHash = "sha256-v4w8oPksEhkJaoqGIr+aj/u5lmPfwzsS1kGtRLbb6eo=";
        };

        # Filter out user/build artifacts so changes to them don't bust
        # the build cache and they don't leak into the derivation.
        cleanedSrc = lib.cleanSourceWith {
          src = ./.;
          filter = path: type:
            let base = baseNameOf (toString path); in
            !(builtins.elem base [
              ".nimby" "nimcache" "out" "dist" "nim.cfg"
              ".venv" "__pycache__" ".git"
            ]);
        };

        bitworld = pkgs.stdenv.mkDerivation {
          pname = "bitworld";
          version = "0.1.0";
          src = cleanedSrc;
          nativeBuildInputs = [ pkgs.nim pkgs.pkg-config pkgs.makeWrapper ];
          buildInputs = runtimeLibs;

          LD_LIBRARY_PATH = lib.makeLibraryPath runtimeLibs;
          LIBRARY_PATH = lib.makeLibraryPath runtimeLibs;

          configurePhase = ''
            runHook preConfigure
            cp -r --no-preserve=mode ${vendoredDeps} .nimby
            # Re-root the workspace's --path entries so nim finds them
            # from the project root (.nimby/<name>/src instead of <name>/src).
            sed 's|--path:"|--path:".nimby/|' .nimby/nim.cfg > nim.cfg
            runHook postConfigure
          '';

          buildPhase = ''
            runHook preBuild
            export HOME=$TMPDIR
            mkdir -p out
            ${lib.concatMapStringsSep "\n" (b: ''
              echo ">>> Building ${b}"
              nim c "${b}.nim"
            '') bitworldBins}
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out/libexec/bitworld $out/bin $out/share/bitworld

            # The compiled binaries themselves (not user-facing — wrappers below).
            for f in out/*; do
              [[ -f "$f" && -x "$f" ]] || continue
              install -m 0755 "$f" "$out/libexec/bitworld/$(basename "$f")"
            done

            # Copy each game's data/ tree, preserving the repo's layout so
            # binaries can keep using their existing CWD-relative paths
            # (e.g. "data/pallete.png").
            for d in */data; do
              [[ -d "$d" ]] || continue
              mkdir -p "$out/share/bitworld/$(dirname "$d")"
              cp -r "$d" "$out/share/bitworld/$d"
            done

            # among_them keeps its runtime assets loose in among_them/
            # rather than under a data/ subdir, so copy them explicitly.
            mkdir -p "$out/share/bitworld/among_them"
            for f in among_them/*.png among_them/*.json among_them/*.aseprite; do
              [[ -f "$f" ]] || continue
              cp "$f" "$out/share/bitworld/among_them/"
            done

            # One wrapper per binary that chdirs into the binary's source
            # directory before exec — that's the CWD the games expect.
            ${lib.concatMapStringsSep "\n" (b:
              let
                binName = baseNameOf b;
                gameDir = dirOf b;
              in ''
                mkdir -p "$out/share/bitworld/${gameDir}"
                makeWrapper "$out/libexec/bitworld/${binName}" "$out/bin/${binName}" \
                  --chdir "$out/share/bitworld/${gameDir}"
              ''
            ) bitworldBins}
            runHook postInstall
          '';
        };

        dockerImage = pkgs.dockerTools.buildLayeredImage {
          name = "bitworld";
          tag = "latest";
          contents = [
            bitworld
            pkgs.bashInteractive
            pkgs.coreutils
          ] ++ runtimeLibs;
          config = {
            Env = [
              "PATH=/bin"
              "LD_LIBRARY_PATH=${lib.makeLibraryPath runtimeLibs}"
            ];
            Cmd = [ "/bin/bash" ];
          };
        };
      in {
        packages = lib.optionalAttrs isLinux {
          inherit bitworld dockerImage vendoredDeps;
          default = bitworld;
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            nim
            nimble
            nimby
            git
            pkg-config
          ] ++ runtimeLibs;

          LD_LIBRARY_PATH = lib.makeLibraryPath runtimeLibs;
          LIBRARY_PATH = lib.makeLibraryPath runtimeLibs;

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
