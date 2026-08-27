{
  description = "Touch ID-gated GitHub credentials for macOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          package = pkgs.stdenv.mkDerivation {
            pname = "gh-touchid";
            version = "0.1.0";
            src = self;

            nativeBuildInputs = [
              pkgs.makeWrapper
              pkgs.swift
            ];

            dontConfigure = true;

            buildPhase = ''
              runHook preBuild
              swiftc -O \
                Sources/GHTouchID/main.swift \
                -o gh-touchid \
                -framework Foundation \
                -framework LocalAuthentication \
                -framework Security
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              install -Dm755 gh-touchid "$out/libexec/gh-touchid"
              makeWrapper "$out/libexec/gh-touchid" "$out/bin/gh-touchid" \
                --set GH_TOUCHID_GH "${pkgs.gh}/bin/gh" \
                --prefix PATH : "${pkgs.lib.makeBinPath [ pkgs.git ]}"
              makeWrapper "$out/libexec/gh-touchid" "$out/bin/gh" \
                --set GH_TOUCHID_GH "${pkgs.gh}/bin/gh" \
                --prefix PATH : "${pkgs.lib.makeBinPath [ pkgs.git ]}" \
                --add-flags gh
              runHook postInstall
            '';

            meta = {
              description = "Touch ID-gated GitHub credentials for macOS";
              homepage = "https://github.com/GeorgeLubaretsi/gh-touchid";
              license = pkgs.lib.licenses.mit;
              mainProgram = "gh-touchid";
              platforms = pkgs.lib.platforms.darwin;
            };
          };
        in
        {
          default = package;
          gh-touchid = package;
        });

      devShells = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.mkShell {
            packages = [
              self.packages.${system}.default
              pkgs.git
              pkgs.swift
            ];
          };
        });

      formatter = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in pkgs.nixfmt-tree);
    };
}
