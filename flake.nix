{
  description = "An exercise in server setup";

  inputs.app1-infrastruktur = {
    url = "github:emanueljg/app1-infrastruktur";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  inputs.nodehill-home-page = {
    url = "github:emanueljg/nodehill-home-page/php-and-mongodb";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  inputs.https-server-proxy = {
    url = "github:emanueljg/https-server-proxy";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-22.11";

  outputs = { self, nixpkgs, ... }@inputs: let
    name = "devop22"; 
  in {
    nixosModules = let
      module = { config, pkgs, lib, ... }: with lib; with builtins; let

        cfg = config.services.${name};
        syspkgs = config.environment.systemPackages;

        mkCfg = attrset: mkIf cfg.enable attrset;

        ALL_STACKS = [ 1 2 3 4 ];

        mkStackEnables = stacks: map (x: cfg."stack${toString x}".enable) stacks;
        mkAllStackEnables = mkStackEnables ALL_STACKS; 

        anyStackEnable = stacks: any trivial.id (mkStackEnables stacks);
        
        mkStackCfg = stackOrStacks: attrset: let
          stacks = lists.toList stackOrStacks;
        in mkIf (cfg.enable && (anyStackEnable stacks)) attrset;
        
      in with types; {
        options.services.devop22 = {

          enable = mkEnableOption (mdDoc "devop22");

          nodePkg = mkOption {
            type = package;
            default = pkgs.nodejs-18_x;
            description = mdDoc ''
              Which node version to run the app with.
            '';
          };

          settingsPath = mkOption {
            type = str;
            description = mdDoc ''
              Path to the settings.json to run.
            '';
            example = literalMD ''
              /var/run/${name}-settings.json"
            '';
          };

          served = mkOption {
            description = mdDoc ''
              A submodule mapping FQDNs to what they serve.

              Allowed values are:
                - main (main app to be run, depends on stack enabled)
                - docs (served html docs of this project)
            '';
            type = listOf (submodule {
              options = {
                FQDN = mkOption {
                  type = str;
                  description = mdDoc ''
                    The fully-qualified domain name of the service.
                  '';
                };
                app = mkOption {
                  type = enum [ "main" "docs" ];
                  description = mdDoc ''
                    What application to serve to the FQDN. 
                  '';
                };
                port = mkOption {
                  type = int;
                  description = mdDoc ''
                    What internal port to target.
                  '';
                };
              };
            });
          };

          # UNIX USER STUFF

          user = mkOption {
            type = types.str;
            default = name;
            description = mdDoc ''
              User account under which devop22 infrastructure runs.
            '';
          };

          group = mkOption {
            type = types.str;
            default = name;
            description = mdDoc ''
              Group under which devop22 infrastructure runs.
            '';
          };

          # STACKS

          stack1 = mkOption {
            description = mdDoc ''
              Stack 1-related options.

              DB: MySQL
              app: node backend. https://github.com/emanueljg/app1-infrastruktur
              process manager: pm2 as a systemd service
              reverse proxy: node, https://github.com/emanueljg/https-server-proxy
            '';
            type = submodule {
              options = {
                enable = mkEnableOption (mdDoc "stack 1");
              };
            };
          };

          stack2 = mkOption {
            description = mdDoc ''
              Stack 2-related options.

              DB: MySQL
              app: a wordpress website
              reverse proxy: apache
            '';
            type = submodule {
              options = {
                enable = mkEnableOption (mdDoc "stack 2");
              };
            };
          };

          stack3 = mkOption {
            description = mdDoc ''
              Stack 2-related options.

              DB: MongoDB
              app: a website, https://github.com/emanueljg/nodehill-home-page
              fastcgi: phpfpm
              reverse proxy + server: nginx
            '';
            type = submodule {
              options = {
                enable = mkEnableOption (mdDoc "stack 3");
              };
            };
          };

          stack4 = mkOption {
            description = mdDoc ''
              Stack 4, for test course.
            '';
            type = submodule {
              options = {
                enable = mkEnableOption (mdDoc "stack 4");
              };
            };
          };

        };

        config = let

          getAnFQDN = FQDN: (
            (lists.findSingle 
              (served: served.app == FQDN)
              null
              "multiple"
              cfg.served).FQDN
          );

          mainFQDN = getAnFQDN "main";
          docsFQDN = getAnFQDN "docs";

          stack1AppPkg = inputs.app1-infrastruktur.packages.${pkgs.system}.default.overrideAttrs (_: {
            postInstall = ''
                ln -sf "${cfg.settingsPath}" "$out/lib/node_modules/hej/settings.json"
                cp -r dist $out/lib/node_modules/hej/
              '';
          });

          stack1AppPkgPath = "${stack1AppPkg}/lib/node_modules/hej";

          stack1ProxyPkg = let
            proxies = (
              strings.concatMapStringsSep
                ", \n  "
                (proxy: "'${proxy.FQDN}': ${toString proxy.port}")
                cfg.served
            );
          in (inputs.https-server-proxy.packages.${pkgs.system}.default.overrideAttrs(_: {
              postInstall = ''
                cat > $out/lib/node_modules/https-server-proxy/myproxy.js <<'EOF'
                const proxy = require('./index.js');

                proxy.settings({ pathToCerts: '/var/lib/acme' });

                proxy('${mainFQDN}', {
                  ${proxies}
                });
                EOF
              '';
            })
          );

          stack1ProxyPkgPath = "${stack1ProxyPkg}/lib/node_modules/https-server-proxy";

          nhpPkg = inputs.nodehill-home-page.packages.${pkgs.system}.default;

        in mkIf cfg.enable {

          # GLOBAL - NIXPKGS ALLOWUNFREE
          # unfortunately the mongodb driver for php is unfree.
          nixpkgs.config.allowUnfree = true;

          # GLOBAL - UNIX USERS
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

          # GLOBAL - FIREWALL
          networking.firewall.allowedTCPPorts = mkCfg [ 80 443 ];

          # GLOBAL - CERT
          security.acme = {
            acceptTerms = true;
            defaults.email = "emanueljohnsongodin@gmail.com";

            # fixes perms issues later down the line
            certs = mkStackCfg 1 {
              ${mainFQDN} = {
                webroot = "/var/lib/acme/acme-challenge";
                group = mkIf (mainFQDN != null) cfg.group;
              };
              ${docsFQDN} = {
                webroot = mkDefault "/var/lib/acme/acme-challenge";
                group = mkIf (docsFQDN != null) cfg.group;
              };
            };
          };

          # STACK 1, 2 - MYSQL DB
          services.mysql = mkMerge [

            (mkStackCfg [ 1 2 ] {
              enable = true;
              # due to some db package state loitering around after stack2 enabling,
              # it's easier to just keep using mysql80 everywhere full stop.
              package = mkForce pkgs.mysql80;
            })

            # STACK 1 - ENSURE DB AND USER
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

          # STACK 1, 3, 4 - SYSTEMD SERVICES
          systemd.services = let
            User = cfg.user;
            Group = cfg.group;
          in mkStackCfg [ 1 3 4 ] {
            "lumia" = let pm2 = pkgs.pm2; in mkStackCfg 4 {
              path = [ cfg.nodePkg pm2 pkgs.git ];
              script = ''
                export PM2_HOME=$(mktemp -d)
                export PROCESS_FILE=$(mktemp /tmp/XXXXXXX.json)
                export ROOT_DIR=$(mktemp -d)
                export NODE_MODULES=$(mktemp -d)
                
                git clone https://github.com/emanueljg/demo-deploy-action $ROOT_DIR

                sh -c 'cat > $PROCESS_FILE <<'EOF'

                {
                  "apps" : [
                    {
                      "name": "lumia",
                      "script": "./server.js",
                      "cwd": "$ROOT_DIR",
                      "env": {
                        "NODE_PATH": "$NODE_MODULES"
                      }
                    }
                  ]
                }
                EOF'

                ${pm2}/bin/pm2 start $PROCESS_FILE --no-daemon
                rm $PROCESS_FILE
                rm -rf $PM2_HOME
                rm -rf $ROOT_DIR
                rm -rf $NODE_MODULES
              '';
              serviceConfig = {
                inherit User Group;
              };
            };

            "app1-infrastruktur-www" = let pm2 = pkgs.pm2; in mkStackCfg 1 {
              path = [ cfg.nodePkg pm2 stack1AppPkg stack1ProxyPkg ];
              wantedBy = [ "multi-user.target" ];
              script = ''
                export PM2_HOME=$(mktemp -d)
                export PROCESS_FILE=$(mktemp /tmp/XXXXXXX.json)

                cat > $PROCESS_FILE <<'EOF'
                {
                  "apps" : [{
                      "name": "app1-infrastruktur",
                      "script": "./index.js",
                      "cwd": "${stack1AppPkgPath}/backend"
                    },
                    {
                      "name": "https-server-proxy",
                      "script": "./myproxy.js",
                      "cwd": "${stack1ProxyPkgPath}",
                      "env": {
                        "NODE_PATH": "${stack1ProxyPkg}/lib/node_modules"
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
                inherit User Group;
                # hack to allow non-root systemd services to 
                # listen to privileged ports (port <= 1024)
                AmbientCapabilities="CAP_NET_BIND_SERVICE";
              };
            };

            # give nginx access to socket
            "phpfpm-nodehill-home-page".serviceConfig = mkStackCfg 3 {
              inherit User; 
              Group = config.services.nginx.group;
            };

          };

          # STACK 2 - DOCS
          services.httpd = let
            nixosManual = (
              builtins.head (
                builtins.filter 
                  (pkg: pkg.name == "nixos-manual-html")
                  syspkgs
              )
            );
            # overriding doesn't seem to work here.
            # probably due to some intricate manual-generation stuff going on.
            # So by rolling our own derivation, we effectively copy over the old manual
            # and add on a postInstall.
            myNixosManual = pkgs.stdenv.mkDerivation {
              name = nixosManual.name;
              src = nixosManual;
              buildInputs = [ pkgs.python310 pkgs.python3Packages.beautifulsoup4 ];
              # this basically takes the normal online nixos manual (but existing locally),
              # scrapes it with python using BeautifulSoup and deletes everything that 
              # hasn't got to do with devop22,
              # otherwise it would be quite the hefty manual.
              # And yes, this is literally just nmd (gitlab.com/rycee/nmd) but in-place,
              # but this ad-hoc solution seemed much simpler. Also, nmd at the time of writing this
              # has 0 docs or blogs written about it. I've dug around esoteric library functions enough
              # as-is.
              postInstall = ''
                # copy files over
                cp -r . $out

                # make script
                cat > fixerscript.py <<'EOF'
                from bs4 import BeautifulSoup

                txt = None
                with open('share/doc/nixos/options.html', 'r') as f:
                  txt = f.read()

                soup = BeautifulSoup(txt)
                li = soup.find('dl', class_='variablelist')
                for dt in li.find_all('dt'):
                  if 'devop22' not in dt.find(lambda t: t.name == 'a' and t.has_attr('id'))['id']: 
                    dt.decompose()
                for dd in li.find_all('dd'):
                  if dd.find('table'):
                    dd.decompose()

                print(soup.prettify())

                EOF

                # run script
                python3 fixerscript.py > $out/share/doc/nixos/index.html
              '';
            };

            nixosManualDir = "${myNixosManual}/share/doc/nixos";
          in {
            virtualHosts.${docsFQDN} = {
              enableACME = true;
              forceSSL = true;
              servedDirs = [{
                dir = nixosManualDir;
                urlPath = "/";
              }];
            };
          };

          # STACK 2 - WORDPRESS
          # sample pages currently: /foo, /bar
          services.wordpress = mkIf cfg.stack2.enable {
            sites.${mainFQDN} = {
              virtualHost = {
                http2 = true;
                enableACME = true;
                forceSSL = true;
              };
            };
          };

          # STACK 3 - PHPFPM
          services.phpfpm.pools."nodehill-home-page" = mkStackCfg 3 {
            user = cfg.user;
            group = cfg.group;
            settings = {
              "pm" = "dynamic";
              "pm.max_children" = 75;
              "pm.start_servers" = 10;
              "pm.min_spare_servers" = 5;
              "pm.max_spare_servers" = 20;
              "pm.max_requests" = 500;
            };
            phpPackage = pkgs.php.buildEnv {
              extensions = ({ enabled, all }: enabled ++ (with all; [
                mongodb
              ]));
            };
          };

          # STACK 3 - NGINX
          services.nginx = mkStackCfg [ 3 4 ] {
            enable = true;
            virtualHosts."4.boxedloki.xyz" = {
              enableACME = true;
              forceSSL = true;
              locations."/" = {
                proxyPass = "http://localhost:3000";
              };
            };

            virtualHosts.${mainFQDN} = mkStackCfg 3 {
              root = "${nhpPkg}/lib/node_modules/vite-project/dist";

              # tweaks
              enableACME = true;
              forceSSL = true;
              http2 = true;

              extraConfig = ''
                error_page 404 =200 /index.html;
              '';

              # locations
              locations = {
                "/" = {
                  index = "index.html";
                  tryFiles = "$uri $uri/ =404";
                };
                "~ \\.php$" = {
                  fastcgiParams = {
                    "SCRIPT_FILENAME" = "$document_root$fastcgi_script_name";
                  };
                  extraConfig = let
                    inherit (config.services.phpfpm.pools."nodehill-home-page") socket;
                    inherit (config.services.nginx) package;
                  in ''
                    fastcgi_pass unix:${socket};
                  '';
                };
              };
            };
          };

          # STACK 3 - MONGODB
          services.mongodb = mkStackCfg 3 {
            enable = true;
          };

          # STACK 1, 3 - DB SEEDER SCRIPTS
          environment.systemPackages = with pkgs; (
            (lists.optional cfg.stack1.enable
              (writeShellApplication {
                name = "app1-infrastruktur-seed";
                runtimeInputs = [ cfg.nodePkg ];
                text = ''
                  export NODE_PATH="${stack1AppPkg}/lib/node_modules"
                  cd ${stack1AppPkgPath}
                  npm_config_cache=$(mktemp -d) 
                  npm run seed-db --cache "$npm_config_cache";
                  rm -rf "$npm_config_cache"
                '';
              })
            )
            ++
            (lists.optional cfg.stack3.enable 
              (writeShellScriptBin 
                "nodehill-home-page-seed" ''
                  ${mongodb-tools}/bin/mongorestore \
                    --drop ${nhpPkg}/lib/node_modules/vite-project/dump
                ''
              )
            )
          );

          # GLOBAL - ASSERTIONS
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
