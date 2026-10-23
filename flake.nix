{
  description = "Touch ID-gated GitHub credentials for macOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # gh-touchid's version is the `toolVersion` constant in its sources, which `gh-touchid version` prints and the
      # release workflow checks the tag against.
      version =
        let
          lines = nixpkgs.lib.splitString "\n" (builtins.readFile ./Sources/GHTouchID/BuildConfiguration.swift);
          found = builtins.filter (match: match != null) (map (builtins.match ''let toolVersion = "([^"]+)"'') lines);
        in
        builtins.head (builtins.head found);

      # gh-touchid built from these sources by scripts/build.sh with Xcode.
      fromSource =
        {
          lib,
          stdenvNoCC,
          gh,
          # The Xcode that builds gh-touchid: proprietary, so never in the store; the build calls it where it is
          # installed and refuses any other version.
          xcode ? {
            version = "27.0";
            path = "/Applications/Xcode.app";
          },
        }:
        stdenvNoCC.mkDerivation {
          pname = "gh-touchid";
          inherit version;
          src = self;

          # Xcode lives outside the store: the build reaches it, so it cannot run in a sandbox (`sandbox = false`
          # or `relaxed`).
          __noChroot = true;

          # Keep the linker's ad-hoc signature: no fixup hook may re-sign or strip the executable.
          dontFixup = true;

          dontConfigure = true;

          buildPhase = ''
            runHook preBuild
            export HOME="$TMPDIR"
            bash scripts/build.sh \
              --xcode ${lib.escapeShellArg xcode.path} \
              --xcode-version ${lib.escapeShellArg xcode.version} \
              --gh ${gh}/bin/gh \
              --gh-sha256 "$(sha256sum ${gh}/bin/gh | cut -d ' ' -f 1)" \
              --output gh-touchid
            runHook postBuild
          '';

          # bin/gh-touchid is the executable itself, so that `git setup` finds it on PATH; libexec/bin/gh runs gh
          # through it, for those who put libexec/bin on PATH or take `with-gh`.
          installPhase = ''
            runHook preInstall
            install -Dm755 gh-touchid "$out/bin/gh-touchid"
            ${installWrapper}
            runHook postInstall
          '';

          meta = meta lib;
        };

      # The release tarball pinned in release/nix.json, which the release workflow writes: its files installed with no
      # build tools and nothing outside the store, so it builds with Nix's sandbox on.
      fromRelease =
        pin:
        {
          lib,
          stdenvNoCC,
          fetchurl,
        }:
        stdenvNoCC.mkDerivation {
          pname = "gh-touchid";
          inherit (pin) version;
          src = fetchurl { inherit (pin) url sha256; };

          dontConfigure = true;
          dontBuild = true;

          # The files as released: no fixup hook may strip or re-sign them. Stripping would break gh-touchid's
          # Developer ID signature and re-signing (the aarch64-darwin fixup signs ad hoc) would replace it, losing the
          # hardened runtime and the Keychain's trust across updates; either would change the bundled gh's SHA-256
          # that gh-touchid checks.
          dontFixup = true;

          # bin/gh-touchid and libexec/gh-touchid as released; libexec/bin/gh written as in the source build, so that it
          # names the executable by its store path.
          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin" "$out/libexec"
            cp bin/gh-touchid "$out/bin/"
            cp -R libexec/gh-touchid "$out/libexec/"
            ${installWrapper}
            runHook postInstall
          '';

          meta = meta lib;
        };

      # The gh wrapper, libexec/bin/gh: `gh-touchid gh "$@"` with this package's gh-touchid. It stays out of bin/, so
      # that the package sits beside any other gh; `with-gh` links it as bin/gh.
      installWrapper = ''
        install -d "$out/libexec/bin"
        printf '#!/bin/sh\nexec %s gh "$@"\n' "$out/bin/gh-touchid" > "$out/libexec/bin/gh"
        chmod 755 "$out/libexec/bin/gh"
      '';

      meta = lib: {
        description = "Touch ID-gated GitHub credentials for macOS";
        homepage = "https://github.com/GeorgeLubaretsi/gh-touchid";
        license = lib.licenses.mit;
        mainProgram = "gh-touchid";
        platforms = lib.platforms.darwin;
      };

      pin = ./release/nix.json;
    in
    {
      # `default` is the pinned release; before the first one, the build from source. Neither puts a `gh` in bin/;
      # `with-gh` is `default` plus bin/gh, a link to its gh wrapper, to replace `gh` in a profile.
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          from-source = pkgs.callPackage fromSource { };
        in
        rec {
          default =
            if builtins.pathExists pin
            then pkgs.callPackage (fromRelease (builtins.fromJSON (builtins.readFile pin))) { }
            else from-source;
          gh-touchid = default;
          inherit from-source;
          with-gh = pkgs.symlinkJoin {
            name = "gh-touchid-with-gh-${default.version}";
            paths = [ default ];
            postBuild = ''
              ln -s ${default}/libexec/bin/gh "$out/bin/gh"
            '';
            inherit (default) meta;
          };
        });

      # `nix run .#check-formula [-- TARBALL]`: the Homebrew formula checked with a throwaway copy of the newest
      # Homebrew (scripts/check-formula.sh), with the tools it needs pinned here.
      apps = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          check-formula = pkgs.writeShellApplication {
            name = "check-formula";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.git
              pkgs.gnused
            ];
            text = ''exec ${self}/scripts/check-formula.sh "$@"'';
          };
        in
        {
          check-formula = {
            type = "app";
            program = "${check-formula}/bin/check-formula";
            meta.description = "Check the Homebrew formula with a throwaway copy of the newest Homebrew";
          };
        });

      # Everything the justfile's recipes call, besides Xcode: Bun runs the tests in tests/.
      devShells = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.mkShell {
            packages = [
              self.packages.${system}.default
              pkgs.actionlint
              pkgs.bun
              pkgs.git
              pkgs.just
              pkgs.shellcheck
            ];
          };
        });

      formatter = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in pkgs.nixfmt-tree);
    };
}
