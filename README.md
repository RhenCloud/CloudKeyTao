# CloudKeyTao

> 星空键道 6（KeyTao）的私有衍生方案包：**编码规则零改动**，只改词库、排序、功能和局部键位。
> 一份产物同时喂 Linux（fcitx5 / Nix）与 Android（fcitx5-android）。

## 这是什么

`CloudKeyTao` 提供**两个 schema**，可随时 A/B 对照：

| schema_id | 名称 | 说明 |
|---|---|---|
| `keytao` | 键道6 | 上游原味，未做任何改动 |
| `cloudkeytao` | CloudKeyTao | 本仓库的自研版本 |

`cloudkeytao` **不是**新输入法 —— 韵母键位、辅助码体系、顶功规则、630 简码全部沿用键道 6，
改动只落在四层：

| 层 | 内容 | 本仓库是否改动 |
|---|---|---|
| 1 | 韵母键位 | ✗ 不动 |
| 2 | 辅助码体系 | ✗ 不动 |
| 3 | 顶功规则 | ✗ 不动 |
| 4 | 选重 / 翻页键 | ✓ 局部 |
| 5 | 词库 / 词频 / 候选排序 | ✓ 主要战场 |
| 6 | 功能开关与 Lua 工具集 | ✓ 增量 |

## 与上游的关系

本仓库是**薄覆盖层**，不复制上游文件：

- 上游 `xkinput/KeyTao` 以 flake input 形式钉在具体 commit；
- 本仓库只包含 `overlay/`（`.custom.yaml` patch）、`lua/`（自研模块）、
  `scripts/`（构建与度量）、`dicts/`（词库加工）；
- 上游升级 = 改一个 rev，然后看 CI 是否还绿。

**纪律：`git diff upstream/main` 永远只有几百行。** 越界即设计失败。

## 目录

```
overlay/                 schema patch（唯一的手写配置面）
lua/                     自研 librime-lua 模块
dicts/                   词库加工产物与被占用编码清单
scripts/                 build.sh / merge-dicts.py / bench.py / gen-occupied-doc.py
bench/                   度量语料与基线
docs/                    设计文档与自动生成的占用清单
.github/workflows/       校验 / 度量 / 上游同步 / 发布
```

## 构建

```bash
# 需要 rime_deployer（nix develop 里自带）
nix develop
./scripts/build.sh          # → dist/rime/
```

Linux 由 Nix 打包安装；Android 直接使用 release 里的 `cloudkeytao-<ver>.zip`。

## 度量

排序改动一律由数字裁决，不靠手感：

```bash
./scripts/bench.py --corpus bench/corpus.txt   # → 首选命中率 / 平均候选位次 / 平均码长 / 空码率
```

`bench/baseline.json` 记录 `{corpus_sha256, git_tag, metrics}`。
**换语料必须重跑基线，不同语料的数字不可跨版本比较。**

## 致谢与授权说明

- **星空键道 6** — 吅吅大山（<https://github.com/xkinput/KeyTao>）。编码规则、词库结构与方案设计版权归原作者。
- **星猫键道 6（xmjd6-rere）** — <https://github.com/hugh7007/xmjd6-rere>。部分词库与 Lua 思路源自此项目；
  依其 README，星猫键道基于吅吅大山老师的星空键道 6.2 获得正式授权。
- **rime-ice** — <https://github.com/iDvel/rime-ice>。词频数据来源。
- **Rime / librime-lua / fcitx5** — 各自由其维护者授权。

本仓库**只包含配置、词库加工脚本与自研 Lua**，不主张对编码规则或上游词库的任何权利。
如原作者认为本仓库的某部分不妥，请开 issue，我会立即移除。
