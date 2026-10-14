{
  description = "Touch ID-gated GitHub credentials for macOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      package =
        {
          lib,
          stdenvNoCC,
          makeWrapper,
          gh,
          git,
          # The Xcode that builds gh-touchid: proprietary, so never in the store; the build calls it where it is
          # installed and refuses any other version.
          xcode ? {
            version = "27.0";
            path = "/Applications/Xcode.app";
          },
        }:
        let
          minimum = "26.0";
          architecture = if stdenvNoCC.hostPlatform.isAarch64 then "arm64" else "x86_64";
          # Xcode's own tools, with nothing of Nix's compiler setup in the way.
          toolchain = ''
            unset SDKROOT NIX_CFLAGS_COMPILE NIX_LDFLAGS MACOSX_DEPLOYMENT_TARGET CC CXX LD
            export DEVELOPER_DIR=${lib.escapeShellArg "${xcode.path}/Contents/Developer"}
            export HOME="$TMPDIR"
            # First line only, without a pipe: `head` closing early is SIGPIPE under pipefail.
            installed="$(/usr/bin/xcodebuild -version 2>&1)" || true
            installed="''${installed%%$'\n'*}"
            if [ "$installed" != ${lib.escapeShellArg "Xcode ${xcode.version}"} ]; then
              echo "gh-touchid: needs Xcode ${xcode.version} at ${xcode.path}; found: $installed" >&2
              exit 1
            fi
            # `-disable-sandbox`: swiftc otherwise runs macro plugins under its own sandbox-exec, which fails as a
            # Nix build user.
            swiftc=(/usr/bin/xcrun --sdk macosx swiftc -O -swift-version 5 -disable-sandbox
              -target ${architecture}-apple-macos${minimum} -module-cache-path "$TMPDIR/modules")
          '';
        in
        stdenvNoCC.mkDerivation {
          pname = "gh-touchid";
          version = "0.3.0";
          src = self;

          nativeBuildInputs = [ makeWrapper ];

          # Xcode lives outside the store: the build reaches it, so it cannot run in a sandbox (`sandbox = false`
          # or `relaxed`).
          __noChroot = true;

          # Keep the linker's ad-hoc signature: no fixup hook may re-sign or strip the executable.
          dontFixup = true;

          dontConfigure = true;

          postPatch = ''
            substituteInPlace Sources/GHTouchID/BuildConfiguration.swift \
              --replace-fail '@gh@' '${gh}/bin/gh'
          '';

          buildPhase = ''
            runHook preBuild
            ${toolchain}
            "''${swiftc[@]}" \
              -module-name GHTouchID \
              Sources/GHTouchID/*.swift \
              -o gh-touchid \
              -framework Foundation \
              -framework AppKit \
              -framework SwiftUI \
              -framework LocalAuthentication \
              -framework LocalAuthenticationEmbeddedUI \
              -framework Security
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            install -Dm755 gh-touchid "$out/libexec/gh-touchid"
            makeWrapper "$out/libexec/gh-touchid" "$out/bin/gh-touchid" \
              --prefix PATH : "${lib.makeBinPath [ git ]}"
            makeWrapper "$out/libexec/gh-touchid" "$out/bin/gh" \
              --prefix PATH : "${lib.makeBinPath [ git ]}" \
              --add-flags gh
            runHook postInstall
          '';

          meta = {
            description = "Touch ID-gated GitHub credentials for macOS";
            homepage = "https://github.com/GeorgeLubaretsi/gh-touchid";
            license = lib.licenses.mit;
            mainProgram = "gh-touchid";
            platforms = lib.platforms.darwin;
          };
        };
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          gh-touchid = pkgs.callPackage package { };
        in
        {
          default = gh-touchid;
          inherit gh-touchid;
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
