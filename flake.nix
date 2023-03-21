{
  description = "An exercise in server setup";

  inputs.https-server-proxy.url = "path:/home/ejg/https-server-proxy";
  inputs.app1-infrastruktur.url = "path:/home/ejg/app1-infrastruktur";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-22.11";

  outputs = { self, nixpkgs, ... }@inputs: let
    name = "devop22"; 
  in {
    nixosModules = let
      module = { config, pkgs, lib, ... }: with lib; with builtins; let

        cfg = config.services.${name};

        mkCfg = attrset: mkIf cfg.enable attrset;

        ALL_STACKS = [ 1 2 ];

        mkStackEnables = stacks: map (x: cfg."stack${toString x}".enable) stacks;
        mkAllStackEnables = mkStackEnables ALL_STACKS; 

        anyStackEnable = stacks: any trivial.id (mkStackEnables stacks);
        
        mkStackCfg = stackOrStacks: attrset: let
          stacks = lists.toList stackOrStacks;
        in mkIf (cfg.enable && (anyStackEnable stacks)) attrset;
        
      in with types; rec {
        options.services.devop22 = {

          enable = mkEnableOption self.description;

          nodePkg = mkOption {
            type = package;
            default = pkgs.nodejs-18_x;
            description = ''
              Which node version to run the app with.
            '';
          };

          settingsPath = mkOption {
            type = str;
            description = ''
              Path to the settings.json to run.
            '';
            example = ''
              `"/var/run/${name}-settings.json"`
            '';
          };

          urls = mkOption {
            description = ''
              Url routing for all the web stacks.
            '';
            type = subdomain {
              options = {
                domain = mkOption {
                  type = str;
                  description = ''
                    The base domain. Do not include subdomain here.
                  '';
                };

                mainSubdomain = mkOption {
                  type = str;
                  default = builtins.head cfg.stack1.urls.subdomains;
                  description = ''
                    A subdomain defined in `subDomains` that
                    should be defined as the main subdomain.

                    Defaults to the first item in the
                    `subdomains` list.
                  '';
                };

                subdomains = mkOption {
                  description = ''
                    Subdomains to route.
                  '';
                  type = listOf (submodule {
                    options = {
                      name = mkOption {
                        type = str;
                        description = ''
                          Name of the subdomain.
                        '';
                      };
                      port = mkoption {
                        type = int;
                        description = ''
                          What localhost port to proxy to.
                        '';
                      };
                    };
                  });
                };

              };
            };
          };

          # UNIX USER STUFF

          user = mkOption {
            type = types.str;
            default = name;
            description = lib.mdDoc ''
              User account under which devop22 infrastructure runs.
            '';
          };

          group = mkOption {
            type = types.str;
            default = name;
            description = lib.mdDoc ''
              Group under which devop22 infrastructure runs.
            '';
          };

          # STACKS

          stack1 = mkOption {
            type = submodule {
              options = {
                enable = mkEnableOption "stack 1";
                addSeeder = mkOption {
                  description = ''
                    Add the seeder as the systemd service ${name}-seeder.
                    Does not make it automatically run; start it yourself.
                  '';
                  type = bool;
                  default = true;
                };

              };
            };
          };

          stack2 = mkOption {
            type = submodule {
              options = {
                enable = mkEnableOption "stack 2";
              };
            };
          };

        };

        config = mkIf cfg.enable {

          users = { 
            groups = mkIf (cfg.group == name) {
              ${name} = { };
            };
            users = mkIf (cfg.user == name) {
              ${name} = {
                group = cfg.group;
                description = "${name} daemon user";
                isSystemUser = true;
              };
            };
          };

          networking.firewall.allowedTCPPorts = mkCfg [ 80 443 ];

          # CERT

          security.acme = {
            acceptTerms = true;
            defaults.email = "emanueljohnsongodin@gmail.com";
          };

          security.acme.certs."1.boxedloki.xyz" = mkStackCfg 1 {
            webroot = "/var/lib/acme/acme-challenge";
            group = cfg.group;
          };

          services.mysql = mkMerge [

            (mkStackCfg [ 1 2 ] {
              enable = true;
              # due to some db package state loitering around after stack2 enabling,
              # it's easier to just keep using mysql80 everywhere full stop.
              package = mkForce pkgs.mysql80;
            })

            (mkStackCfg 1 {
              ensureDatabases = [ "cinema" ];
              ensureUsers = [{
                name = cfg.user;
                ensurePermissions = {
                  "cinema.*" = "ALL PRIVILEGES";
                };
              }];
            })

          ];

          systemd.services = let
            stack1app = inputs.app1-infrastruktur.packages.${pkgs.system}.default.overrideAttrs (_: {
              postInstall = ''
                  ln -sf "${cfg.settingsPath}" "$out/lib/node_modules/hej/settings.json"
                  cp -r dist $out/lib/node_modules/hej/
                '';
            });
            proxyPkg = (
              inputs.https-server-proxy.packages.${pkgs.system}.default.overrideAttrs(_: {
                postInstall = ''
                  cat > $out/lib/node_modules/https-server-proxy/myproxy.js <<'EOF'
                  const proxy = require('./index.js');

                  proxy.settings({ pathToCerts: '/var/lib/acme' });

                  proxy('1.boxedloki.xyz', {
                    '1.boxedloki.xyz': 4000,
                    '2.boxedloki.xyz': 34001,
                    '3.boxedloki.xyz': 34002
                  });
                  EOF
                '';
              })
            );
            path = [ stack1app cfg.nodePkg pkgs.bash ];
            WorkingDirectory = "${stack1app}/lib/node_modules/hej";
            User = cfg.user;
            Group = cfg.group;
          in mkStackCfg 1 {

            "${name}-seeder" = mkIf cfg.stack1.addSeeder {
              inherit path;
              script = ''
                npm_config_cache=$(mktemp -d) 
                ${cfg.nodePkg}/bin/npm run seed-db --cache "$npm_config_cache";
                rm -rf $npm_config_cache
              '';
              serviceConfig = {
                Type = "oneshot";
                inherit WorkingDirectory User Group;
              };
            };

            "${name}" = let pm2 = pkgs.pm2; in {
              path = path ++ [ pm2 proxyPkg ];
              wantedBy = [ "multi-user.target" ];
              script = ''
                export PM2_HOME=$(mktemp -d)
                export PROCESS_FILE=$(mktemp /tmp/XXXXXXX.json)

                cat > $PROCESS_FILE <<'EOF'
                {
                  "apps" : [{
                      "name": "app1-infrastruktur",
                      "script": "./index.js",
                      "cwd": "${WorkingDirectory}/backend"
                    },
                    {
                      "name": "https-server-proxy",
                      "script": "./myproxy.js",
                      "cwd": "${proxyPkg}/lib/node_modules/https-server-proxy",
                      "env": {
                        "NODE_PATH": "${proxyPkg}/lib/node_modules"
                      }
                    }
                  ]
                }
                EOF

                ${pm2}/bin/pm2 start $PROCESS_FILE --no-daemon
                rm $PROCESS_FILE
                rm -rf $PM2_HOME
              '';
              serviceConfig = {
                # hack to allow non-root systemd services to 
                # listen to privileged ports (port <= 1024)
                AmbientCapabilities="CAP_NET_BIND_SERVICE";
                inherit User Group;
              };
            };

          };

          # STACK 2 WORDPRESS SETUP
          # sample pages:
          # https://1.boxedloki.xyz/foo
          # https://1.boxedloki.xyz/bar
          services.wordpress = mkIf cfg.stack2.enable {
            sites."1.boxedloki.xyz" = {
              virtualHost = {
                http2 = true;
                enableACME = true;
                forceSSL = true;
              };
            };
          };

          assertions = [
            { 
              assertion = (lists.count trivial.id mkAllStackEnables) <= 1;
              message = ''
                Only one stack can be enabled at a time. 
                Other assertions might possibly come up, too,
                due to this faulty setup.
              '';
            }
          ];

        };

      };

    in { default = module; ${name} = module; };
  };
}
