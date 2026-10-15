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

          # bin/gh-touchid is the executable itself, so that `git-setup` finds it on PATH; bin/gh runs gh through it.
          installPhase = ''
            runHook preInstall
            install -Dm755 gh-touchid "$out/bin/gh-touchid"
            printf '#!/bin/sh\nexec %s gh "$@"\n' "$out/bin/gh-touchid" > "$out/bin/gh"
            chmod 755 "$out/bin/gh"
            runHook postInstall
          '';

          meta = meta lib;
        };

      # The release tarball pinned in release/nix.json, which the release workflow writes: unpacked as it is, with no
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

          # The files as released: no fixup hook may strip or re-sign them, which would also change the bundled gh's
          # SHA-256 that gh-touchid checks.
          dontFixup = true;

          installPhase = ''
            runHook preInstall
            mkdir -p "$out"
            cp -R bin libexec "$out/"
            runHook postInstall
          '';

          meta = meta lib;
        };

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
      # `default` is the pinned release; before the first one, the build from source.
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
        });

      devShells = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.mkShell {
            packages = [
              self.packages.${system}.default
              pkgs.git
            ];
          };
        });

      formatter = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in pkgs.nixfmt-tree);
    };
}
