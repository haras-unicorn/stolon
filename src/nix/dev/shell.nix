{ selfLib, ... }:

{
  self.devShells.default = {
    flake = true;
    value =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      let
        yaml = pkgs.formats.yaml { };

        toml = pkgs.formats.toml { };

        json = pkgs.formats.json { };

        prettierConfig = yaml.generate "prettier.yaml" {
          printWidth = 80;
          tabWidth = 2;
          useTabs = false;
          trailingComma = "all";
          endOfLine = "lf";
          proseWrap = "always";
        };

        cspellRoot = yaml.generate "cspell.yaml" {
          useGitignore = true;
          version = "0.2";
          language = "en";
          ignorePaths = [ "CHANGELOG.md" ];
          words = [
            "btrfs"
            "direnv"
            "disko"
            "fstrim"
            "gcroot"
            "gcroots"
            "haraspkgs"
            "impermanence"
            "kvm"
            "luks"
            "nixfmt"
            "nixos"
            "nixpkgs"
            "stolon"
            "subvolume"
            "subvolumes"
            "udev"
            "udevadm"
            "zstd"
            "nocow"
            "nodev"
            "nushell"
            "unspanned"
            "mktemp"
            "subvol"
            "gnused"
            "cooldown"
            "haras"
            "restic"
            "pkgs"
            "bubblewrap"
            "langservers"
            "treefmt"
            "bwrap"
            "dotenv"
            "cachix"
            "nvme"
            "chattr"
            "noatime"
            "mountpoint"
            "MNTPOINT"
            "Workqueues"
            "vfat"
            "fstype"
            "cryptsetup"
            "coreutils"
            "PARTLABEL"
            "FSTYPE"
            "blockdevices"
            "partlabel"
            "subvolid"
            "nodeps"
            "noheadings"
            "GXNX"
            "ints"
            "fsprogs"
            "readlink"
            "esac"
            "reflogs"
            "oneshot"
            "tmpfiles"
            "stdenv"
            "virtualisation"
            "secretsecret"
            "subtest"
            "nbackuppw"
            "backuppw"
            "workqueue"
            "mountpoints"
            "mdbook"
            "mkpasswd"
            "passwd"
            "sdb"
            "zfs"
          ];
        };

        markdownlintConfig = json.generate "markdownlint.json" {
          "$schema" =
            "https://raw.githubusercontent.com/DavidAnson/markdownlint/main/schema/markdownlint-config-schema.json";
        };

        helixServers = lib.mapAttrs (
          _: server:
          {
            inherit (server) command;
          }
          // lib.optionalAttrs (server.arguments != [ ]) {
            args = server.arguments;
          }
          // lib.optionalAttrs (server.config != { }) {
            inherit (server) config;
          }
        ) config.languages.servers;

        helixLanguages = lib.mapAttrsToList (
          name: language:
          {
            inherit name;
            auto-format = language.auto-format;
          }
          // lib.optionalAttrs (language.servers != [ ]) {
            language-servers = language.servers;
          }
          // lib.optionalAttrs (language.formatter != null) {
            formatter = {
              inherit (language.formatter) command;
            }
            // lib.optionalAttrs (language.formatter.arguments != [ ]) {
              args = language.formatter.arguments;
            };
          }
        ) config.languages.languages;

        helixLanguagesToml = toml.generate "languages.toml" (
          lib.optionalAttrs (helixServers != { }) {
            language-server = helixServers;
          }
          // lib.optionalAttrs (helixLanguages != [ ]) {
            language = helixLanguages;
          }
        );

        nixfmtWrapped = pkgs.harasPackages.makeBubblewrapWrapper {
          name = "nixfmt";
          package = pkgs.nixfmt;
        };

        prettierWrapped = pkgs.harasPackages.makeBubblewrapWrapper {
          name = "prettier";
          package = pkgs.prettier;
        };

        cspellWrapped = pkgs.harasPackages.makeBubblewrapWrapper {
          name = "cspell";
          package = pkgs.cspell;
        };

        hxWrapped = pkgs.harasPackages.makeBubblewrapWrapper {
          name = "hx";
          package = pkgs.helix;
          files = {
            "~/.cache/helix" = {
              mode = "rw";
            };
            ".helix/languages.toml" = {
              mode = "ro";
              source = helixLanguagesToml;
            };
          };
        };

        external = [
          pkgs.nil
          pkgs.nix
          pkgs.fd
          pkgs.yaml-language-server
          pkgs.vscode-langservers-extracted
          pkgs.markdownlint-cli
          pkgs.marksman
          pkgs.treefmt
        ];
      in
      {
        packages = [
          pkgs.mdbook
          pkgs.harasPackages.flake-root
          nixfmtWrapped
          prettierWrapped
          cspellWrapped
          hxWrapped
        ]
        ++ external;

        bwrap.files = {
          "cspell.yaml".source = cspellRoot;
        };

        git = {
          enable = true;
          ignore = {
            templates = [ "Nix" ];
            patterns = ''
              # Repository

              .env
              docs/book
            '';
          };
          attributes = ''
            * text=auto eol=lf
          '';
        };

        # Generated from the options, and compared with the committed page by
        # the file check, so the page cannot drift from the code.
        file."docs/src/options.md".text = ''
          # Options

          <!-- markdownlint-disable MD013 -->

        ''
        + builtins.readFile (selfLib.docs.options pkgs);

        direnv = {
          enable = true;
          extra = "dotenv_if_exists .env";
        };

        editorconfig = {
          enable = true;
          settings."*" = {
            end_of_line = "lf";
            charset = "utf-8";
            max_line_length = 80;
            indent_style = "space";
            indent_size = 2;
            tab_width = 2;
            insert_final_newline = true;
            trim_trailing_whitespace = true;
          };
        };

        languages = {
          servers = {
            nil.command = "nil";

            yaml-language-server = {
              command = "yaml-language-server";
              arguments = [ "--stdio" ];
            };

            marksman = {
              command = "marksman";
              arguments = [ "server" ];
            };

            vscode-json-language-server = {
              command = "vscode-json-language-server";
              arguments = [ "--stdio" ];
              config = {
                provideFormatter = true;
                format.enable = true;
                json.validate.enable = true;
              };
            };
          };

          languages = {
            nix = {
              servers = [ "nil" ];
              formatter = {
                command = lib.getExe pkgs.nixfmt;
                arguments = [
                  "--filename"
                  "%{buffer_name}"
                ];
              };
            };

            yaml = {
              servers = [ "yaml-language-server" ];
              formatter = {
                command = lib.getExe pkgs.prettier;
                arguments = [
                  "--config"
                  (builtins.toString prettierConfig)
                  "--parser"
                  "yaml"
                ];
              };
            };

            json = {
              servers = [ "vscode-json-language-server" ];
              formatter = {
                command = lib.getExe pkgs.prettier;
                arguments = [
                  "--config"
                  (builtins.toString prettierConfig)
                  "--parser"
                  "json"
                ];
              };
            };

            markdown = {
              servers = [ "marksman" ];
              formatter = {
                command = lib.getExe pkgs.prettier;
                arguments = [
                  "--config"
                  (builtins.toString prettierConfig)
                  "--parser"
                  "markdown"
                ];
              };
            };
          };
        };

        license = {
          enable = true;
          spdx = "MIT";
          path = "LICENSE.md";
          attrs = {
            "<year>" = "2026";
            "<copyright holders>" = "github@haras-unicorn.net";
          };
        };

        codeOfConduct.contributorCovenant = {
          enable = true;
          path = "CODE_OF_CONDUCT.md";
        };

        workflows = {
          check = {
            on.pull_request = { };

            matrix.os = [
              "ubuntu-latest"
            ];

            installable = null;

            steps = [
              {
                run = "nix flake check --show-trace --print-build-logs --max-jobs 1 --keep-going";
              }
            ];
          };

          docs = {
            on.push.branches = [ "main" ];

            permissions = {
              pages = "write";
              "id-token" = "write";
            };

            installable = ".#docs";

            steps = [
              {
                uses = "actions/upload-pages-artifact@v3";
                "with".path = "./result";
              }
            ];

            jobs.deploy = {
              needs = "build";
              runs-on = "ubuntu-latest";
              environment = {
                name = "github-pages";
                url = "\${{ steps.deployment.outputs.page_url }}";
              };
              steps = [
                {
                  id = "deployment";
                  uses = "actions/deploy-pages@v4";
                }
              ];
            };
          };

          release = {
            on.push.branches = [ "main" ];

            permissions = {
              contents = "write";
              "pull-requests" = "write";
            };

            installable = null;
            installNix = false;
            cachix = null;

            steps = [
              {
                uses = "googleapis/release-please-action@v4";
                "with" = {
                  command = "manifest";
                  token = "\${{ secrets.RELEASE_PLEASE_TOKEN }}";
                  "config-file" = ".release-please-config.json";
                  "manifest-file" = ".release-please-manifest.json";
                  "default-branch" = "main";
                };
              }
            ];
          };
        };

        check.checks = {
          docs = {
            packages = [ pkgs.mdbook ];
            commands = "mdbook build docs --dest-dir \"$(mktemp -d)\"";
          };

          cspell = {
            packages = [ cspellWrapped ];
            commands = "cspell lint . --no-progress";
          };

          markdownlint = {
            packages = [ pkgs.markdownlint-cli ];
            commands = ''
              markdownlint --config ${markdownlintConfig} --ignore-path .gitignore --ignore CHANGELOG.md --ignore LICENSE.md .
            '';
          };

          nil = {
            packages = [
              pkgs.fd
              pkgs.nil
            ];
            commands = ''
              status=0
              output="$(fd --glob '*.nix' . -0 | xargs -0 -r nil diagnostics 2>&1)" || status=$?
              if [ -n "$output" ]; then
                printf '%s\n' "$output" >&2
                status=1
              fi
              test "$status" -eq 0
            '';
          };
        };

        format.formatters = {
          nixfmt = {
            packages = [ nixfmtWrapped ];
            command = "nixfmt";
            includes = [ "*.nix" ];
          };

          prettier = {
            packages = [ prettierWrapped ];
            command = "prettier";
            options = [
              "--write"
              "--config"
              (builtins.toString prettierConfig)
            ];
            includes = [
              "*.json"
              "*.md"
              "*.yaml"
              "*.yml"
            ];
            excludes = [
              "flake.lock"
              ".release-please-manifest.json"
              "CHANGELOG.md"
              "LICENSE.md"
            ];
          };
        };
      };
  };
}
