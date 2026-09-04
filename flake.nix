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
          curl    # italkalot/ivotewell dlopen libcurl.so via the curly dep
        ];

        # Parse nimby.lock and fetch each dep via builtins.fetchGit.
        # No fixed-output hash needed — revs pin the content.
        parseLockLine = line:
          let parts = builtins.filter builtins.isString (builtins.split " " line);
          in if builtins.length parts >= 4 then {
            name = builtins.elemAt parts 0;
            url = builtins.elemAt parts 2;
            rev = builtins.elemAt parts 3;
          } else null;
        lockContents = builtins.readFile ./nimby.lock;
        lockLines = builtins.filter (l: l != "")
          (builtins.filter builtins.isString (builtins.split "\n" lockContents));
        rawLockEntries = builtins.filter (e: e != null) (map parseLockLine lockLines);
        # Hard-error on duplicate dep names. We can't silently dedupe: two
        # entries can pin different revs, and picking one arbitrarily would
        # produce a build that disagrees with the lockfile.
        nameCounts = lib.foldl'
          (acc: n: acc // { ${n} = (acc.${n} or 0) + 1; })
          {} (map (e: e.name) rawLockEntries);
        duplicateNames =
          builtins.attrNames (lib.filterAttrs (_: c: c > 1) nameCounts);
        lockEntries =
          if duplicateNames != [] then
            throw ("nimby.lock has duplicate entries for: "
              + lib.concatStringsSep ", " duplicateNames
              + ". Remove the extra line(s) so each dep appears exactly once.")
          else rawLockEntries;
        # NAR hash for each dep, keyed by name with the rev it was computed
        # against. Passing the narHash to fetchGit alongside `rev` lets Nix
        # verify the cache locally and skip the remote ref poll that
        # builtins.fetchGit otherwise does on every eval (which timed out
        # badly on flaky networks). The rev is recorded so that bumping
        # nimby.lock without refreshing the narHash trips a clear
        # flake-eval-time error pointing at the stale entry, rather than a
        # downstream "NAR hash mismatch". Regenerate with:
        #   nix eval --impure --json --expr 'let
        #     parseLockLine = line: let parts = builtins.filter builtins.isString
        #       (builtins.split " " line); in if builtins.length parts >= 4 then
        #       { name = builtins.elemAt parts 0; url = builtins.elemAt parts 2;
        #         rev = builtins.elemAt parts 3; } else null;
        #     entries = builtins.filter (e: e != null) (map parseLockLine
        #       (builtins.filter (l: l != "") (builtins.filter builtins.isString
        #         (builtins.split "\n" (builtins.readFile ./nimby.lock)))));
        #   in builtins.listToAttrs (map (e: { inherit (e) name; value = {
        #     inherit (e) rev;
        #     narHash = (builtins.fetchGit { inherit (e) url rev;
        #       allRefs = true; }).narHash; }; }) entries)'
        narHashes = {
          bumpy = { rev = "8f4d5ee2005af166b0a08e64e2035f8ff27f1531"; narHash = "sha256-8E9v1SQkNoKvtkOYBZGQ8slcQafrgL+9Os3Dp9VtGOA="; };
          chroma = { rev = "2381748f92e5ea16cb2403ff7e20c6dd5443a59d"; narHash = "sha256-9+vWgkdSmSErGqhDZNY0vX80nWrvpkPHT1z+BxRTXOY="; };
          crunchy = { rev = "98eb6526982bb8aae8eec6e8781f4539fa19e049"; narHash = "sha256-kc3aSwYjJZb4LqGMDK+Kf0bGEAsl9eUFv7yNN0QTP4Y="; };
          curly = { rev = "a0f42baacbc48f4e5924b18854c0df9dcc251466"; narHash = "sha256-7nMzwatfQMVzodtr4PdgA1cx5aLb+FlgrXxoBHOfYwA="; };
          dx12 = { rev = "11f7fd5a6223e71d52a360f701145e63f306559f"; narHash = "sha256-W9CUCvHGGP0gln6XuDloYrAj6IOR8OpER0FWyAYw8/E="; };
          flatty = { rev = "05d878b397933331966a7f80dd0c55664559201f"; narHash = "sha256-F7o7xt3C3uVmC6jmpO2N24uBcxDw+FN6rls55Mzi050="; };
          fluffy = { rev = "2012906732cc104dc08fb80a3cec976ddfd9a98a"; narHash = "sha256-UrYur6xtwBQc6vUOb2ctkpYI2NQ8RY2OktOOdb6xfuU="; };
          jsony = { rev = "fbbf55e94e204d7daf583813d79f7327c8001d17"; narHash = "sha256-+GFwfWMzzBRd+WA7exVO+k8vYkWi+0+0GmBgFfvN12g="; };
          libcurl = { rev = "7a420498f60a31d99fc8513886ce36c4e8c3a4ae"; narHash = "sha256-NmyVuzZ9DiBJqHxlf3Sj+JTbCZdUjrJKQ6x3Dg4XTjk="; };
          metal4 = { rev = "46d0bc5afd65a563ecf9c5c93004b357733594c1"; narHash = "sha256-Q7nemftJZrfhLbf2xsG/LLc3Y2Bm0EHnUgMNRJt7oUY="; };
          mummy = { rev = "3bcb1e3f7aec9530fe03404eb7468cdfdb14fedb"; narHash = "sha256-YSxEaP2lB58/Gbf7fsHCh2d5Q5zCdTRGGwTlV9eeb+0="; };
          nimsimd = { rev = "3f6b2668ffb0867d0bf786a658b817763e611350"; narHash = "sha256-FO7ty/NIE/fNfGiiEaoAHLEb26fQCqai5V0ERYbEPTs="; };
          opengl = { rev = "8e2e098f82dc5eefd874488c37b5830233cd18f4"; narHash = "sha256-v3bMDobYQZqX0anBFIUfZx5q5/vxTHO6PDtKQlf5mgU="; };
          paddy = { rev = "3fcec08a559479cc8d2fd769f26c6d56bb27a1a1"; narHash = "sha256-EutdbqnNtCruJ7YftU1pJqxH2RQC5g/PzBWX/oN+wQE="; };
          pixie = { rev = "6d47166df0c89c91be4e712734f78af24c4d8361"; narHash = "sha256-J6Z4NURxFx3zRuZsmZtnTuF8KuROabqVstlpsnj7j68="; };
          shady = { rev = "c89db58632c5442df16251b3e15cb43c5d52e2a6"; narHash = "sha256-vSA148l9edMFwCP0aXzz5iLyO4xhu8O67G79dfvmHTI="; };
          silky = { rev = "d5225513d6496138d4e29b6930af22172c1fe75b"; narHash = "sha256-4GnH/0/GQWBNdStRRrF+Ja5vfuKXdq7koG+nVGHAtwQ="; };
          supersnappy = { rev = "ff8fe2bffefc1f4edc15deb20d921f600babb8c4"; narHash = "sha256-SDLsHtgiyheAn62T6c/39KD215dI/gm3JzMj3yYY768="; };
          taggy = { rev = "0013a4bf921dc9fa735f81577518b2c1e155f062"; narHash = "sha256-yQtKh7Ur831n+3MXtbYbCvDHkXAvrOyTbOTsyReQ3Dc="; };
          urlly = { rev = "99784779f05649df25fd9c33003d8ef6de027345"; narHash = "sha256-QWsm2JMTwmBKW7lp3lY2SPVavg2kNZeq4J5mCXkJRDc="; };
          vk14 = { rev = "68841f5e1a13247e7a463bfe79beb27232cbd6c5"; narHash = "sha256-RhRnQiMKjhI3kKsHA82PcKOfJGHlK8mB7tXn6CnB+A0="; };
          vmath = { rev = "7bd9f6e6b23ca3b751be42f20c8025d320881a00"; narHash = "sha256-+/MneL0PzErOFaIj9CoUAY+xPDrIhoAPXaV9pXiV9ZU="; };
          webby = { rev = "55a2c03abbd32abf4775712c1959d975dc982549"; narHash = "sha256-cKefl4h5Wcels+mLRyeE8l4E5wVK7cV/h1NczZATHVk="; };
          whisky = { rev = "494fb1046f5a563defc87ac36b8c62846ee7ea2c"; narHash = "sha256-3P3lKk7ZY5t6R3C0bssGSmvUcI9auOSs5utPzEhfgAw="; };
          windy = { rev = "1b5f60bbd2027729d661ccab2c19fcaec6ef9376"; narHash = "sha256-jAZcAHSoioFY/7qZmmkv52uP/HMXWF9w+q2LNUnLP4k="; };
          ws = { rev = "cbb8f763b436669392d10baec2a45778395395cc"; narHash = "sha256-RpSeUGUt9Q8hFCGXjmKUNcWHkByDq3ys32Ak8wvPm4g="; };
          zippy = { rev = "bcb8c1e1be6abb0a0e35a3c6040cdd9391cc993f"; narHash = "sha256-Y5c4Rk9esBiWFYlh2WFc251eCA+VWyn7rxnLka4CYW4="; };
        };
        narHashFor = entry:
          let pinned = narHashes.${entry.name} or null; in
          if pinned == null then
            throw ("flake.nix narHashes is missing entry for '"
              + entry.name + "'. Regenerate the narHashes attrset "
              + "(see comment above).")
          else if pinned.rev != entry.rev then
            throw ("flake.nix narHashes['" + entry.name
              + "'] is pinned to rev " + pinned.rev
              + " but nimby.lock pins " + entry.rev
              + ". Regenerate the narHashes attrset (see comment above).")
          else pinned.narHash;
        # Some deps (e.g. libcurl) keep their .nim files at the package root
        # rather than under src/. Emit the right --path for each at build
        # time by probing the dep, mirroring what `nimby sync` produces.
        vendoredDeps = pkgs.runCommand "bitworld-deps" {} (''
          mkdir -p $out
          : > $out/nim.cfg
        '' + lib.concatMapStrings (entry: ''
          ln -s ${builtins.fetchGit {
            url = entry.url;
            rev = entry.rev;
            allRefs = true;
            narHash = narHashFor entry;
          }} $out/${entry.name}
          if [ -d "$out/${entry.name}/src" ]; then
            echo '--path:"${entry.name}/src"' >> $out/nim.cfg
          else
            echo '--path:"${entry.name}"' >> $out/nim.cfg
          fi
        '') lockEntries);

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
              $out/share/bitworld/among_them $out/share/bitworld/client
            install -m 0755 out/among_them $out/libexec/bitworld/among_them
            cp -r client/data $out/share/bitworld/client/
            # The server reads these via clientStaticPath() at runtime so
            # the /player, /global, /admin, /reward routes can render their
            # HTML directly out of the image.
            install -m 0644 -t $out/share/bitworld/client/ \
              client/player_client.html \
              client/global_client.html \
              client/admin_client.html \
              client/reward_client.html \
              client/snappyjs.min.js \
              client/qrcode.min.js
            for f in among_them/*.png among_them/*.json among_them/*.aseprite; do
              [[ -f "$f" ]] || continue
              cp "$f" $out/share/bitworld/among_them/
            done
            makeWrapper $out/libexec/bitworld/among_them $out/bin/among_them \
              --chdir $out/share/bitworld/among_them
            runHook postInstall
          '';
        });

        # The bot shares the game's assets but launches from its source
        # dir among_them/players/<name>/, so its gameDir() walks two
        # levels up to find
        # spritesheet.png et al.
        mkAmongThemBot = name: pkgs.stdenv.mkDerivation (commonAttrs // {
          pname = "bitworld-${name}";
          buildPhase = ''
            runHook preBuild
            export HOME=$TMPDIR
            mkdir -p out
            nim c among_them/players/${name}/${name}.nim
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p $out/libexec/bitworld $out/bin \
              $out/share/bitworld/among_them/players/${name} \
              $out/share/bitworld/client
            install -m 0755 out/${name} $out/libexec/bitworld/${name}
            cp -r client/data $out/share/bitworld/client/
            for f in among_them/*.png among_them/*.json among_them/*.aseprite; do
              [[ -f "$f" ]] || continue
              cp "$f" $out/share/bitworld/among_them/
            done
            makeWrapper $out/libexec/bitworld/${name} $out/bin/${name} \
              --chdir $out/share/bitworld/among_them/players/${name}
            runHook postInstall
          '';
        });
        bitworldNottoodumb = mkAmongThemBot "nottoodumb";
        bitworldItalkalot = mkAmongThemBot "italkalot";
        bitworldIvotewell = mkAmongThemBot "ivotewell";

        dockerImageAmongThem = pkgs.dockerTools.buildLayeredImage {
          name = "bitworld-among_them";
          tag = "latest";
          contents = [
            bitworldAmongThem
            pkgs.bashInteractive
            pkgs.coreutils
            pkgs.curl # Used to extract logs at runtime in cloudflare
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

        mkBotDockerImage = name: bot: pkgs.dockerTools.buildLayeredImage {
          name = "bitworld-${name}";
          tag = "latest";
          contents = [
            bot
            pkgs.bashInteractive
            pkgs.coreutils
            pkgs.curl # Used to extract logs at runtime in cloudflare
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
            Cmd = [ "/bin/${name}" ];
          };
        };
        dockerImageNottoodumb = mkBotDockerImage "nottoodumb" bitworldNottoodumb;
        dockerImageItalkalot = mkBotDockerImage "italkalot" bitworldItalkalot;
        dockerImageIvotewell = mkBotDockerImage "ivotewell" bitworldIvotewell;

        # On darwin, reference the aarch64-linux packages so that
        # `nix build .#dockerImageAmongThem` works on both platforms.
        # The nix-darwin linux-builder handles the actual compilation.
        linuxDockerImageAmongThem = if isLinux then dockerImageAmongThem
          else self.packages."aarch64-linux".dockerImageAmongThem;
        linuxDockerImageNottoodumb = if isLinux then dockerImageNottoodumb
          else self.packages."aarch64-linux".dockerImageNottoodumb;
        linuxDockerImageItalkalot = if isLinux then dockerImageItalkalot
          else self.packages."aarch64-linux".dockerImageItalkalot;
        linuxDockerImageIvotewell = if isLinux then dockerImageIvotewell
          else self.packages."aarch64-linux".dockerImageIvotewell;

        # Single store path containing all four image tarballs as named
        # symlinks, for `nix build .#dockerImages` convenience.
        dockerImages = pkgs.runCommand "bitworld-docker-images" {} ''
          mkdir -p $out
          ln -s ${linuxDockerImageAmongThem}  $out/among_them.tar.gz
          ln -s ${linuxDockerImageNottoodumb} $out/nottoodumb.tar.gz
          ln -s ${linuxDockerImageItalkalot}  $out/italkalot.tar.gz
          ln -s ${linuxDockerImageIvotewell}  $out/ivotewell.tar.gz
        '';

      in {
        packages = {
          dockerImageAmongThem = linuxDockerImageAmongThem;
          dockerImageNottoodumb = linuxDockerImageNottoodumb;
          dockerImageItalkalot = linuxDockerImageItalkalot;
          dockerImageIvotewell = linuxDockerImageIvotewell;
          inherit dockerImages;
        } // lib.optionalAttrs isLinux {
          inherit vendoredDeps;
          default = dockerImageAmongThem;
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            nim
            nimble
            nimby
            git
            pkg-config
            terraform
            awscli2
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
