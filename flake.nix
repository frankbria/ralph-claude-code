{
  description = "Ralph for Claude Code - Autonomous AI development loop";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        ralph = pkgs.stdenv.mkDerivation {
          pname = "ralph-claude-code";
          version = "1.0.0";

          src = ./.;

          nativeBuildInputs = [ pkgs.makeWrapper ];

          # Runtime dependencies
          buildInputs = [
            pkgs.bash
            pkgs.jq
            pkgs.git
            pkgs.nodejs
            pkgs.tmux
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.gnused
          ];

          installPhase = ''
            runHook preInstall

            # Create directories
            mkdir -p $out/bin
            mkdir -p $out/share/ralph
            mkdir -p $out/share/ralph/templates
            mkdir -p $out/share/ralph/lib

            # Copy templates
            cp -r templates/* $out/share/ralph/templates/

            # Copy lib scripts
            cp -r lib/* $out/share/ralph/lib/

            # Copy main scripts
            cp ralph_monitor.sh $out/share/ralph/
            cp ralph_import.sh $out/share/ralph/
            cp setup.sh $out/share/ralph/

            # Copy and patch ralph_loop.sh - replace SCRIPT_DIR with actual nix store path
            sed -e 's|SCRIPT_DIR="\$(dirname "\''${BASH_SOURCE\[0\]}")"||' \
                -e "s|source \"\\\$SCRIPT_DIR/lib/|source \"$out/share/ralph/lib/|g" \
                -e "s|\\\$SCRIPT_DIR/ralph_monitor.sh|$out/share/ralph/ralph_monitor.sh|g" \
                -e "s|\\\$SCRIPT_DIR/ralph_loop.sh|$out/share/ralph/ralph_loop.sh|g" \
                ralph_loop.sh > $out/share/ralph/ralph_loop.sh

            # Make scripts executable
            chmod +x $out/share/ralph/*.sh
            chmod +x $out/share/ralph/lib/*.sh

            # Create main ralph command
            cat > $out/bin/ralph << EOF
#!/usr/bin/env bash
RALPH_HOME="$out/share/ralph"
export RALPH_HOME
exec "\$RALPH_HOME/ralph_loop.sh" "\$@"
EOF

            # Create ralph-monitor command
            cat > $out/bin/ralph-monitor << EOF
#!/usr/bin/env bash
RALPH_HOME="$out/share/ralph"
export RALPH_HOME
exec "\$RALPH_HOME/ralph_monitor.sh" "\$@"
EOF

            # Create ralph-setup command
            cat > $out/bin/ralph-setup << EOF
#!/usr/bin/env bash
set -e

PROJECT_NAME=\''${1:-"my-project"}
RALPH_HOME="$out/share/ralph"

echo "🚀 Setting up Ralph project: \$PROJECT_NAME"

# Create project directory in current location
mkdir -p "\$PROJECT_NAME"
cd "\$PROJECT_NAME"

# Create structure
mkdir -p {specs/stdlib,src,examples,logs,docs/generated}

# Copy templates from Ralph home
cp "\$RALPH_HOME/templates/PROMPT.md" .
cp "\$RALPH_HOME/templates/fix_plan.md" @fix_plan.md
cp "\$RALPH_HOME/templates/AGENT.md" @AGENT.md
cp -r "\$RALPH_HOME/templates/specs/"* specs/ 2>/dev/null || true

# Initialize git
git init
echo "# \$PROJECT_NAME" > README.md
git add .
git commit -m "Initial Ralph project setup"

echo "✅ Project \$PROJECT_NAME created!"
echo "Next steps:"
echo "  1. Edit PROMPT.md with your project requirements"
echo "  2. Update specs/ with your project specifications"
echo "  3. Run: ralph --monitor"
echo "  4. Monitor: ralph-monitor (if running manually)"
EOF

            # Create ralph-import command
            cat > $out/bin/ralph-import << EOF
#!/usr/bin/env bash
RALPH_HOME="$out/share/ralph"
export RALPH_HOME
exec "\$RALPH_HOME/ralph_import.sh" "\$@"
EOF

            # Make all bin scripts executable
            chmod +x $out/bin/*

            # Wrap all scripts with PATH containing required tools
            for script in $out/bin/*; do
              wrapProgram "$script" \
                --prefix PATH : ${pkgs.lib.makeBinPath [
                  pkgs.bash
                  pkgs.jq
                  pkgs.git
                  pkgs.nodejs
                  pkgs.tmux
                  pkgs.coreutils
                  pkgs.gnugrep
                  pkgs.gnused
                ]}
            done

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Autonomous AI development loop with intelligent exit detection and rate limiting";
            homepage = "https://github.com/frankbria/ralph-claude-code";
            license = licenses.isc;
            platforms = platforms.unix;
            mainProgram = "ralph";
          };
        };

      in {
        packages = {
          default = ralph;
          ralph-claude-code = ralph;
        };

        apps = {
          default = {
            type = "app";
            program = "${ralph}/bin/ralph";
          };
          ralph = {
            type = "app";
            program = "${ralph}/bin/ralph";
          };
          ralph-monitor = {
            type = "app";
            program = "${ralph}/bin/ralph-monitor";
          };
          ralph-setup = {
            type = "app";
            program = "${ralph}/bin/ralph-setup";
          };
          ralph-import = {
            type = "app";
            program = "${ralph}/bin/ralph-import";
          };
        };

        # Development shell with all dependencies
        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.bash
            pkgs.jq
            pkgs.git
            pkgs.nodejs
            pkgs.tmux
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.gnused
            pkgs.bats
          ];

          shellHook = ''
            echo "🚀 Ralph for Claude Code development environment"
            echo "Available commands: ralph, ralph-monitor, ralph-setup, ralph-import"
            export RALPH_HOME="${self}/share/ralph"
          '';
        };
      }
    );
}
