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
          openssl # nottoodumb dynamically loads libssl for wss:// connects
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
          outputHash = "sha256-nCB1qYc8S8N8b7+N2fagzmgERE426+jbfbvfykNn7ds=";
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

        # Shared build chrome for both packages: nim toolchain wired up to
        # vendoredDeps, runtime libs on LD_LIBRARY_PATH so dlopen'd things
        # (libssl, libGL, ...) work both at build and at runtime.
        commonAttrs = {
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
        };

        # Compiles among_them, copies its runtime assets into the standard
        # repo-shaped layout under share/, and wraps the binary so it
        # chdirs into share/bitworld/among_them at exec time (matching the
        # CWD getCurrentDir()-based asset paths in sim.nim expect).
        bitworldAmongThem = pkgs.stdenv.mkDerivation (commonAttrs // {
          pname = "bitworld-among_them";
          buildPhase = ''
            runHook preBuild
            export HOME=$TMPDIR
            mkdir -p out
            nim c among_them/among_them.nim
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p $out/libexec/bitworld $out/bin \
              $out/share/bitworld/among_them $out/share/bitworld/clients
            install -m 0755 out/among_them $out/libexec/bitworld/among_them
            cp -r clients/data $out/share/bitworld/clients/
            for f in among_them/*.png among_them/*.json among_them/*.aseprite; do
              [[ -f "$f" ]] || continue
              cp "$f" $out/share/bitworld/among_them/
            done
            makeWrapper $out/libexec/bitworld/among_them $out/bin/among_them \
              --chdir $out/share/bitworld/among_them
            runHook postInstall
          '';
        });

        # The bot shares the game's assets but launches from
        # among_them/players/ — same CWD quick_player gives it — so its
        # gameDir() walks one level up to find spritesheet.png et al.
        bitworldNottoodumb = pkgs.stdenv.mkDerivation (commonAttrs // {
          pname = "bitworld-nottoodumb";
          buildPhase = ''
            runHook preBuild
            export HOME=$TMPDIR
            mkdir -p out
            nim c among_them/players/nottoodumb.nim
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p $out/libexec/bitworld $out/bin \
              $out/share/bitworld/among_them/players \
              $out/share/bitworld/clients
            install -m 0755 out/nottoodumb $out/libexec/bitworld/nottoodumb
            cp -r clients/data $out/share/bitworld/clients/
            for f in among_them/*.png among_them/*.json among_them/*.aseprite; do
              [[ -f "$f" ]] || continue
              cp "$f" $out/share/bitworld/among_them/
            done
            makeWrapper $out/libexec/bitworld/nottoodumb $out/bin/nottoodumb \
              --chdir $out/share/bitworld/among_them/players
            runHook postInstall
          '';
        });

        dockerImageAmongThem = pkgs.dockerTools.buildLayeredImage {
          name = "bitworld-among_them";
          tag = "latest";
          contents = [
            bitworldAmongThem
            pkgs.bashInteractive
            pkgs.coreutils
            pkgs.tini
          ] ++ runtimeLibs;
          config = {
            Env = [
              "PATH=/bin"
              "LD_LIBRARY_PATH=${lib.makeLibraryPath runtimeLibs}"
            ];
            # tini at PID 1 so SIGINT/SIGTERM actually reach the binary;
            # the kernel drops default-action signals to PID 1, so without
            # an init `podman run` Ctrl+C silently does nothing.
            Entrypoint = [ "/bin/tini" "--" ];
            Cmd = [ "/bin/among_them" ];
          };
        };

        dockerImageNottoodumb = pkgs.dockerTools.buildLayeredImage {
          name = "bitworld-nottoodumb";
          tag = "latest";
          contents = [
            bitworldNottoodumb
            pkgs.bashInteractive
            pkgs.coreutils
            pkgs.tini
            pkgs.cacert # bots dial out over wss://, need a trust store
          ] ++ runtimeLibs;
          # pkgs.cacert ships /etc/ssl/certs/ca-bundle.crt; Nim's std/net
          # hardcodes the Debian path ca-certificates.crt and ignores
          # SSL_CERT_FILE in its default verifyMode, so symlink it.
          extraCommands = ''
            ln -sf ca-bundle.crt etc/ssl/certs/ca-certificates.crt
          '';
          config = {
            Env = [
              "PATH=/bin"
              "LD_LIBRARY_PATH=${lib.makeLibraryPath runtimeLibs}"
            ];
            Entrypoint = [ "/bin/tini" "--" ];
            Cmd = [ "/bin/nottoodumb" ];
          };
        };
      in {
        packages = lib.optionalAttrs isLinux {
          inherit vendoredDeps dockerImageAmongThem dockerImageNottoodumb;
          default = dockerImageAmongThem;
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
