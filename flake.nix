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
        stdenvNoCC.mkDerivation {
          pname = "gh-touchid";
          inherit version;
          src = self;

          nativeBuildInputs = [ makeWrapper ];

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
          from-source = pkgs.callPackage fromSource { };
        in
        rec {
          default = from-source;
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
