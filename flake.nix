{
  description = "CloudKeyTao —— 键道6 的独立方案（薄覆盖层，可发布、可 rebase）";

  # ── 上游 pin ────────────────────────────────────────────────────────────────
  # 所有上游输入都钉死到 commit。CI（upstream-sync.yml）只负责**提议**升级，
  # 真正挪 pin 是人工 review 后改这里的 rev。
  #
  # 为什么不直接在构建时从本地 clone 取？
  #   那样构建结果就依赖本机 git 状态，两台机器可能产出不同 dist/。
  #   flake input 是纯的、可复现的，且 `nix flake update` 可审计。
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # 骨架方案：词库、Lua 模块、punctuator、recognizer 等全部来自这里。
    KeyTao = {
      url = "github:xkinput/KeyTao/3e11969655105b267aceebd5b2594374b8dfe7cc";
      flake = false;
    };

    # 词库来源（M2 起启用）：星猫键道6。M1 不消费，先钉住以保证将来可复现。
    xmjd6 = {
      url = "github:hugh7007/xmjd6-rere/d13d9fcaf8364605aeb85f7217b6a2f1dffcf72d";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      KeyTao,
      xmjd6,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in
    {
      # ── devShell：构建与验证所需的一切 ──────────────────────────────────────
      devShells = forAllSystems (
        pkgs:
        let
          python = pkgs.python3.withPackages (p: [ p.pyyaml ]);
        in
        {
          default = pkgs.mkShell {
            packages = [
              python
              pkgs.git
              pkgs.jq
              pkgs.shellcheck
              # rime_deployer：部署/编译验证，CI 与本地用同一份
              pkgs.librime
              # luac：语法检查（上游 scripts/validate.sh 也用它）
              pkgs.lua5_4
            ];

            # build.sh 读取这些环境变量。指向 flake input 的 store 路径，
            # 因此 `nix develop` 一进来就能直接跑 `./scripts/build.sh`。
            KEYTAO_SRC = "${KeyTao}";
            XMJD6_SRC = "${xmjd6}";

            # rime_deployer 需要的共享数据目录（预设方案、opencc 基础数据）。
            RIME_SHARED = "${pkgs.fcitx5-rime}/share/rime-data";

            shellHook = ''
              echo "CloudKeyTao devShell"
              echo "  KEYTAO_SRC = $KEYTAO_SRC"
              echo "  XMJD6_SRC  = $XMJD6_SRC"
              echo
              echo "  ./scripts/build.sh        构建 dist/rime/"
              echo "  ./scripts/validate.sh     部署验证（rime_deployer）"
            '';
          };
        }
      );

      # ── 产物包：可被 NixOS 模块直接 xdg.dataFile 消费 ──────────────────────
      # 这是「单源真相」的落点：Linux 与安卓吃的是同一份 dist/rime/。
      packages = forAllSystems (pkgs: {
        rime-data =
          pkgs.runCommand "cloudkeytao-rime-data"
            {
              nativeBuildInputs = [
                pkgs.python3
                pkgs.librime
              ];
              CLOUDKEYTAO_ROOT = "${self}";
              KEYTAO_SRC = "${KeyTao}";
              XMJD6_SRC = "${xmjd6}";
              PYTHON = "python3";
            }
            ''
              export HOME=$TMPDIR
              bash ${self}/scripts/build.sh --out "$out"
            '';

        default = self.packages.${pkgs.stdenv.hostPlatform.system}.rime-data;
      });

      # ── 部署验证：CI 与本地共用 ────────────────────────────────────────────
      checks = forAllSystems (pkgs: {
        deploy =
          pkgs.runCommand "cloudkeytao-deploy-check"
            {
              nativeBuildInputs = [
                pkgs.librime
                pkgs.python3
              ];
            }
            ''
              export HOME=$TMPDIR
              cp -r ${self.packages.${pkgs.stdenv.hostPlatform.system}.rime-data} rime
              chmod -R u+w rime
              set +e
              rime_deployer --build rime ${pkgs.fcitx5-rime}/share/rime-data build \
                > deploy.log 2>&1
              deploy_rc=$?
              set -e
              if grep -qE '^E[0-9]' deploy.log; then
                echo "部署失败："
                grep -E '^E[0-9]' deploy.log
                exit 1
              fi
              test "$deploy_rc" -eq 0
              test -f build/cloudkeytao.extended.table.bin
              touch $out
            '';
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}
