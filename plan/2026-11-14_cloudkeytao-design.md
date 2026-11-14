# CloudKeyTao 设计方案（共识稿 v1）

> 状态：**待确认**。确认后才开始写代码。
> 日期：2026-11-14
> 基线仓库：`github.com/xkinput/KeyTao`（星空键道6，上游） / `github.com/hugh7007/xmjd6-rere`（星猫键道6，词库来源）
> 目标仓库：`github.com/RhenCloud/CloudKeyTao`，本地 `~/Project/CloudKeyTao`

---

## 0. 一页摘要

把「键道6 + 一堆事后覆盖脚本」升级成「一个可构建、可度量、可回滚的私有方案包」：

- **编码规则零改动**。键道6 的双拼/辅助码/顶功/630 简码原样保留。
- **改动只落在 5 层（词库与排序）、6 层（功能）、4 层（键位局部）**。
- **产物同源**：一份 `dist/rime/`，Linux（Nix）+ 安卓（fcitx5-android 手拷）都吃它。
- **双 schema 并存**：`keytao`（原味对照）+ `cloudkeytao`（你的），随时 A/B。
- **可度量**：重排前后用 bench 出数字，不靠手感。
- **薄覆盖层**：`git diff upstream/main` 永远只有几百行，上游升级 = 改一个 pin。

---

## 1. 已定决策表（设计树）

| # | 决策点 | 结论 |
|---|---|---|
| Q1 | 痛点 | (a) 词库/候选排序 · (c) 缺功能 · (d) 部署太脏 |
| Q2 | 交付形态 | **B.** 私有 fork 方案（可发布、可 rebase 的薄 diff） |
| Q3 | 改动边界 | 只动 **4 键位 / 5 词库排序 / 6 功能*；不动 1 韵母键位 / 2 辅助码 / 3 顶功 |
| Q4 | 平台 | **Linux + 安卓 fcitx5** |
| Q5 | 骨架基线 | **C.** KeyTao 作骨架 + 按需移植 xmjd6 的 Lua 模块 |
| Q6 | 能力 | a 反查 ✓ · b 自造词/整句 ✓ · c 工具集按需 · d 统计**推迟** · e 快符冻结 · f 候选加工 ✓ · g 文本加工按需 |
| Q7 | 部署 | **A.** 单源真相：一份 `dist/` 喂 Linux 与安卓 |
| Q8 | 身份 | **C.** 双 id 并存：`keytao` + `cloudkeytao` |
| Q9 | 反查触发 | **C.** 用 `` ` `` 引导，`u/v/o` 字根原样保留 |
| Q10 | 已存在的 a/i 冲突 | **B.** 继续征用，但把被占用编码**机器化归档** |
| Q11 | 词频管线 | **D.** 算 weight + 稳定排序文件 |
| Q12 | 打字统计 | 推迟（M4 后另议） |
| Q13 | 安卓形态 | **A.** 逻辑同源；触屏差异靠候选栏滑动 + 方案菜单；以后视情况换 trime |
| Q14 | 仓库形态 | **B.** 薄覆盖层 + 上游 pin；CI 负责校验/bench/发布 |
| Q15 | 词库来源 | **B.** xmjd6（星猫键道6） |
| Q15′ | 筛选规则 | **A.** 词组库只取 ≥4 码；单字库单独处理 |
| Q16 | 验收 | **B.** 可测基线（首选命中率 / 平均候选位次 / 平均码长 / 空码率） |
| Q17 | 发布 | **公开 + 发 release**，README 致谢即可（不额外做授权审查） |
| Q18 | 翻页键 | **B.** 回归键道原生 `-` / `=`；`,` `.` 还给标点 |
| Q19 | 占用清单 | YAML 机器可读为唯一真相 + CI 生成 md |
| Q20 | bench 语料 | 先用**公共占位语料**跑通管线，你本人的真实文本后续替换 |
| Q21 | 单字库 | **A.** `xmjd6.danzi` 全量并入 |
| Q22 | `;` 快符 | **A.** 进第一版，`;` 语义不动 |
| Q23 | 仓库名/路径 | `RhenCloud/CloudKeyTao` + `~/Project/CloudKeyTao` |
| Q24 | 里程碑 | M1 骨架 → M2 词库 → M3 功能 → M4 打磨 |
| Q25 | 新并入单字权重 | **A.** 统一 `5`（低于 keytao 的 10–14），只作"打得出"兜底 |
| Q26 | 授权处理 | README 致谢即可，不做授权审查（你的决定） |
| Q27 | M1 占位语料 | 中文维基百科条目摘录（CC BY-SA 4.0），约 1500 字；语料可替换，**基线可重跑** |

---

## 2. 事实基线（实测，非估计）

### 2.1 现状痛点根因

| 事实 | 数值 | 含义 |
|---|---|---|
| `keytao.phrase` 条目 | 123,868 | 词库主体 |
| 其中权重 = 100 | 123,868（100%） | **`sort: by_weight` 形同虚设** |
| 权重 101/102 | 129 | 手工微调痕迹 |
| `keytao.single` 权重刻度 | 10–14 | **与 phrase 不同刻度**，合并需归一化 |
| phrase + single 唯一码 | 141,837 | 同码候选 97% 只有 1 个 |

> **结论：候选顺序 ≈ 文件行序。** 想改排序，本质是"给 weight 填真值 / 重排行序"，
> 而不是改 schema 里的哪个开关。

### 2.2 xmjd6 词库现状

| 词库 | 行数 | 列 | 唯一码 | 有 weight？ |
|---|---|---|---|---|
| `xmjd6.cizu` | 372,473 | `text<Tab>code` | — | **无** |
| `xmjd6.fjcy` | 520,516 | `text<Tab>code` | 499,967 | **无** |
| `xmjd6.danzi` | 35,640 | `text<Tab>code` | 32,379 | **无** |
| 合计唯一码 | 884,135 | | | |

> **关键**：xmjd6 README 说的"手动优化排序和权重"**没有体现在数据里**——
> 三个主库全是 2 列、无 weight、`sort: original`。
> 所以它能提供**词条**，不能提供**权重**；权重必须我们自己算（见 §6）。

### 2.3 编码兼容性（决定 merge 可行性）

| 指标 | 数值 |
|---|---|
| xmjd6 唯一码 | 884,135 |
| keytao 唯一码 | 141,837 |
| **交集** | **139,611（98.4%）** |
| 仅 xmjd6 有 | 744,524 |

> **编码规则 98.4% 重合**（同源：星空键道 6.2 → 星猫 6.3），merge 在语法层完全可行。

### 2.4 候选泛滥风险评估（实测，推翻常见担忧）

把 12 万 phrase 与 52 万 fjcy 合并后按码分组：

| 码长 | 码数 | 平均候选 | 最大候选 |
|---|---|---|---|
| 2 | 3 | 1.00 | 1 |
| 3 | 8,190 | 1.01 | 2 |
| 4 | 136,683 | 1.03 | 3 |
| 5 | 243,231 | 1.02 | 2 |
| 6 | 226,713 | **1.09** | **10** |

> **平均候选只从 1.00 涨到 1.09**——因为键道码长上限 6、码空间巨大，
> 88 万条绝大多数是 4–6 码长尾词，各自占坑，**不挤短码**。
> 最大压力点在 6 码的极少数（最坏 `jjciii` = 10 个候选）。
>
> **真正的风险不在"候选多"，而在"短码被垃圾词占位"** —— 见 §6.2 的 ≥4 码筛选规则。

### 2.5 单字库冲突（决定 Q21 的处理方式）

| 指标 | 数值 |
|---|---|
| `keytao.single` 唯一码 | 17,127 |
| `xmjd6.danzi` 唯一码 | 32,379 |
| **完全重合的码** | **17,071** |
| 仅 xmjd6 有 | 15,364 |

> 合并后：1 码档 15,364 条（单候选）、2 码档 17,071 条（**每码 2 候选**）。
> 冲突是**可控的字典序问题**，不是泛滥。

### 2.6 单码占用全表（Q10 的落地依据）

| 单码 | 主库（single/phrase） | supplement / symbol |
|---|---|---|
| `a` | — | 那 又 氵 乛 𠃌 氺 乚（7 个字根） |
| `i` | — | 龵 打 丨 亅 人 上（6 个字根） |
| `o` | — | 啊 着 丶 |
| `u` | — | 得 丿 |
| `v` | — | 有 木 土 士 一 朩 |
| `;` | — | `；`（且 `speller.alphabet` 含 `;` `/` `=`） |
| `b c d e f h j l m n q t w x y z` | 各 1 个高频字 | — |
| `g k p r s` | 各 1 个高频字 | — |

> `u/v/o` 在主库**完全没有**条目（`keytao.single` + `keytao.phrase` 中以 `a/i/o/u/v` 开头的码 = **0**）。
> 这是键道6 的天然空档，也是星猫（xmjd6）敢于征用 `u/v/o` 的原因。
> 你选 Q9=C 不动这个空档，代价是"反查要靠 `` ` `` 引导"。

### 2.7 已有的反查通道（Q9=C 成本极低的原因）

上游 `schema/desktop/keytao.schema.yaml` **已经内置 `` ` `` 反查机制**：

```yaml
recognizer:
  patterns:
    danzi_lookup: "[a-z`]*`+[a-z`]*"
    pinyin: "(?<![`A-Z])`[a-z']*;?$"
filters:
  - reverse_lookup_filter@danzi_lookup
```

另有独立方案 `keytao-cx`（键道6反查，F4 可切）与 `keytao-cx.dict.yaml`（import `keytao.single`）。

> **所以 Q9=C 只需求把 `pinyin_simp` / `liangfen` / `gbk` 三个词库挂到这条既有通道上**，
> 不需要新增触发器、不动 `u/v/o`、不动顶功。

### 2.8 构建产物定义（Q7/Q14 的地基）

上游 `default.nix` 的产物定义只有 4 行核心逻辑：

```
cp -r rime/*            $out/share/rime-data/
cp schema/desktop/*.yaml $out/share/rime-data/
```

> **产物是 trivial 的**，这正是"薄覆盖层"可行的技术前提。

上游 CI 已有：`validate.yml`（`rime_deployer --build` 五平台编译校验）、`release.yml`（打包 zip）。
上游开发体验已有：`scripts/rime_tui.cc`（交互式 librime TUI，可程序化灌码）、`scripts/validate.sh`、`scripts/measure_memory.sh`。

---

## 3. 仓库结构

```
CloudKeyTao/
├── flake.nix                    # 上游 pin + devShell(rime_deployer, luac, librime)
├── flake.lock                   # 钉死上游 commit
├── default.nix                  # 合成 dist/rime 的构建表达式
│
├── overlay/                     # ★ 唯一的手写面（薄覆盖层）
│   ├── cloudkeytao.schema.yaml  # 新 schema_id（从 keytao 派生）
│   ├── cloudkeytao.custom.yaml  # patch：键位 / 过滤器 / 反查 / 词库挂载
│   ├── keytao.custom.yaml       # 原味方案的 patch（保证 A/B 对照时上游也顺手）
│   └── default.custom.yaml      # schema_list：keytao + cloudkeytao（+ keytao-bj）
│
├── lua/                         # 自研 lua（沿用 NixOS-Config 现有 6 个）
│   ├── defer_emoji_filter.lua
│   ├── select_character.lua
│   ├── add_phrase.lua
│   ├── promote_custom_phrase.lua
│   ├── custom_phrase_live.lua
│   └── quick_text.lua
│
├── dicts/
│   ├── cloudkeytao.occupied.dict.yaml   # ★ 被占用编码清单（机器可读，唯一真相）
│   ├── cloudkeytao.user.dict.yaml       # 个人高权词库
│   └── gen/                             # 生成物（不入库，CI artifact）
│
├── scripts/
│   ├── build.sh                 # 合成 dist/rime（Nix 与本地共用同一入口）
│   ├── merge-dicts.py           # xmjd6 词库筛选 / 合并 / 权重计算
│   ├── bench.py                 # 驱动 rime_tui 灌码 → 指标表
│   └── gen-occupied-doc.py      # YAML → docs/occupied-codes.md
│
├── bench/
│   ├── corpus.txt               # ★ 你的真实文本（脱敏），需你提供
│   └── baseline.json            # 改动前基线（M1 产出）
│
├── docs/
│   ├── design.md                # 本文件的仓库内版本
│   ├── occupied-codes.md        # 占用清单（CI 生成）
│   └── changelog.md
│
└── .github/workflows/
    ├── validate.yml             # luac + 两平台 rime_deployer
    ├── bench.yml                # 语义：M2 每次 PR 出指标对比表
    ├── upstream-sync.yml        # 每日检测上游新 commit → 重放 patch → 失败开 issue
    └── release.yml              # dist/ → zip → GitHub Release
```

**纪律**：`overlay/` 以外的目录不许出现上游文件。上游升级只改 `flake.lock` 里那一个 rev。

---

## 4. 构建与产物（Q7=A 的落地）

### 4.1 单一入口

`scripts/build.sh` 是**唯一**产物生成入口，Nix 与本地手动都调它：

```
输入：上游 rime-data（flake input）+ overlay/ + lua/ + dicts/gen/
输出：dist/rime/
       ├── *.dict.yaml          # 上游词库 + 生成的合并词库
       ├── keytao.schema.yaml   # 原味（上游原样）
       ├── cloudkeytao.schema.yaml
       ├── *.custom.yaml
       ├── lua/
       └── opencc/
```

### 4.2 双 schema 的合成方式

`cloudkeytao.schema.yaml` 在**构建期**由上游 `keytao.schema.yaml` 生成：

1. 复制上游 `keytao.schema.yaml` → `cloudkeytao.schema.yaml`
2. 改写 `schema.schema_id: cloudkeytao`、`schema.name: CloudKeyTao`
3. 由 `overlay/cloudkeytao.schema.yaml` 做 YAML 深度合并（不用 `sed`，用 yq/python）

> ⚠️ **M1 验证点**：必须用 `rime_deployer --build` 实测通过。
> 若上游 schema 结构导致合并脆弱，退路是 `__include: keytao.schema.yaml:/` + 覆写
> （需实测确认 librime 对该写法的合并语义）。**这一步失败则 M1 不算完成。**

### 4.3 Linux（NixOS）

`~/Project/NixOS-Config/modules/desktop/fcitx5/home.nix` 改造为：

```nix
programs.rime-keytao.enable = true;                 # 保留上游，保证 keytao 可用
# 新增：把 CloudKeyTao 的 dist/rime 覆盖到用户目录
xdg.dataFile."fcitx5/rime/...".source = "${cloudkeytao}/share/rime-data/...";
```

**并删除**现有的 `home.activation.installRimeLateConfig` 里**所有** `cp -f` / `sed -i` /
`rm -f` / `register_lua` 逻辑 —— 这些正是 Q1(d) 的病灶。
迁移后的职责划分：

| 现在（脏） | 以后（干净） |
|---|---|
| activation 脚本 `cp` 覆盖 yaml | Nix 文件依赖（`xdg.dataFile`） |
| `sed -i` 改 store 里的 `rime.lua` | `rime.lua` 作为**我们自己的文件**进 dist |
| `sed -i` 往 `keytao.extended.dict.yaml` 插 import | 由 `build.sh` 生成最终 extended |
| `convert-rime-ice-to-keytao.py` 每次跑 | 提前生成进 `dicts/gen/`（CI 缓存） |

保留的唯二动态部分：`keytao-custom-phrase-sync` 定时器（周更回流动态造词）——它写回 repo，机制不变。

### 4.4 安卓（fcitx5-android）

- 从 GitHub Release 下载 `cloudkeytao-<ver>.zip` → 解压到 fcitx5-android 的 rime 用户目录。
- 同一份 `dist/rime/`，无平台分叉（Q13=A）。
- **已知触屏差异**（M4 处理，不在 M1–M3 范围）：
  - 无 `F3`/`F4`/`Ctrl+.`/`Ctrl+\` → 开关走方案菜单（`switcher`）。
  - `-`/`=` 翻页在触屏需切换符号页 → M4 视情况加候选栏滑动或专用键位 patch。
  - `[`/`]` 首末选、`'` 次选同理。

---

## 5. 键位决策（层 4）

| 项 | 现状 | 决策 |
|---|---|---|
| 翻页 | 你的 patch 把 `,`/`.` 绑成 `Page_Up/Down` | **回归 `-`/`=`**（键道原生、飞键友好），`,`/`.` 还给标点 |
| 选重 | 数字键 + `[`/`]`（`select_character`）+ `'`（`smart_2`） | 不动 |
| 开关 | `&` emoji、`F6` 方案切换、`F7` 简繁 | 不动 |
| `;` 快符 | `keytao.symbol` 全套 `;` 前缀 | **冻结**（Q22=A，不碰） |
| `u/v/o` | 字根/单字简码 | **不动**（Q9=C） |
| `a/i` | 整句 / 英文（挡住 13 个字根） | **继续征用**（Q10=B） |

**翻页改动的直接收益**：组字过程中可以直接打 `，` `。`，不必先上屏
—— 你现在这个 patch 是「排序差 → 需要频繁翻页」的**症状缓解**，
排序修好后（M2）它的必要性消失，而代价是永久失去中文最高频的两个标点键。

---

## 6. 词库合并管线（层 5，M2 的核心）

### 6.1 来源与筛选规则

| 来源 | 规则 | 预计条目 |
|---|---|---|
| 上游 `keytao.phrase` / `single` / `css` / `supplement` / `symbol` | **全量保留，排序不变** | 141,837 码 |
| `xmjd6.cizu` + `xmjd6.fjcy` | **仅取码长 ≥ 4**（Q15′=A） | ~700k |
| `xmjd6.danzi` | **全量并入**（Q21=A），权重统一 `5` | +15,364 |
| 你已有 `keytao.user` / `keytao.custom.user` | 保留，权重 999 | 现有 |
| `xmjd6.candidate_order` / `chaojizici` / 诗词 / emoji 等 | **不取**（M4 再议） | — |

> **≥4 码筛选的理由**：3 码是键道"三简词"地盘，你已有 7,431 条；
> xmjd6 的 3 码层有 8,387 条，且含 `不饱和`/`白菜丝`/`半瓶醋` 这类明显低频词。
> 它们若插在你的常用词前面 = 直接恶化痛点 (a)。长尾词（≥4 码）则不占短码，纯扩覆盖。

### 6.2 权重刻度

| 层 | 现状刻度 | 处理 |
|---|---|---|
| `keytao.single` 单字 | 10–14 | **保持**（基准） |
| `keytao.phrase` 词组 | 100（全平） | **保持原样**（见下方实测修正） |
| `xmjd6` 并入单字 | 无 | **统一 5**（Q25=A） |
| `xmjd6` 并入词组（≥4码） | 无 | **统一 6**（高于单字、低于词组） |
| `keytao.user` 个人库 | 999 | 保持最高 |

> ⚠️ **【M2 实测修正：原假设不成立】**
>
> 本节原先假设「三套权重刻度必须归一，否则单字会被词组压到后面」。
> 用 librime 真实灌码验证后发现：这个 bug **在当前的 `sort: original` 下不会发生**，
> 因为**权重根本不参与候选排序**。
>
> 两个方向的实测证据：
>
> | 实验 | 结果 |
> |---|---|
> | `extended` 保持 `sort: original`，同码放 w=1 与 w=99999 两条 | 按**文件顺序**排，权重被无视 |
> | 同上，把 `extended` 改成 `sort: by_weight` | 权重立刻接管：`到`(w=10) 被 `道：“`(w=100) 从第 1 压到第 3 |
>
> 机理：`sort:` 写在 dict 头，而 `extended` 是聚合表，它的 `sort: original`
> 覆盖了所有被 import 表的 `sort: by_weight`。
>
> **结论与选择**：两者只能取一。当前选 `sort: original`（权重无效但顺序稳定，
> 上游 14 万条词的相对位置完全不变），因此 **M2 不需要归一权重**。
> 若将来要启用 `by_weight`，必须先做全局归一 —— 那才是本节原本担心的场景。
> 真到那一步再改，而不是现在为不存在的 bug 写归一代码。
>
> 附带好处：`xmjd6` 表在 import_tables 里排**最后**，
> 所以 80 万条并入词不会改变任何一个现有词的位置。

### 6.3 排序策略（Q11=D）

1. 计算每条真实 weight（§6.2；按实测修正，weight 仅作文档记录，不参与排序）
2. `sort: original` 保留在 extended 的 dict 头（候选顺序由 import_tables 顺序决定）
3. **生成时按 `(weight desc, code, text)` 做稳定排序写盘**
   → 保证重跑同样输入得到同样文件（**已实测达成：字节级一致**）
   → 保证 `git diff` 只显示"真的变了哪些词"，而不是 80 万行全变

### 6.4 去重与冲突

- **同 code 同 text**：保留 weight 高者（keytao 优先）。
- **同 code 不同 text**：全部保留，靠 weight 决定顺序（这就是"扩覆盖"）。
- **xmjd6 词条与 keytao 已有词条重复**：保留 keytao 版本（含其 weight 与位置）。
- 生成后断言：
  - 平均候选数 ≤ 1.2（码长加权）
  - 6 码最大候选 ≤ 12
  - 简码（≤3 码）层条目数**不增加**（这是 Q15′ 的硬约束）

---

## 7. 反查（Q9=C，M3）

复用上游既有 `` ` `` 通道，挂三个词库：

| 场景 | 输入 | 说明 |
|---|---|---|
| 拼音反查 | `` `pinyin `` | `pinyin_simp.dict.yaml`（从 xmjd6 取，含笔画提示） |
| 二分反查 | `` `拆字 `` | `liangfen.dict.yaml`（从 xmjd6 取） |
| GBK 字集 | `` `... `` | `xmjd6.gbk.dict.yaml`（繁体/生僻字） |

- 三者共用 `recognizer.patterns.pinyin` 与 `reverse_lookup_filter@danzi_lookup` 的既有语义。
- `u/v/o` 完全不动。
- 候选里同时列出三种结果（同一 `` ` `` 前缀下的多个 translator），按命中类型加注释前缀区分。

> ⚠️ **M3 验证点**：三个词库体量（`liangfen` / `gbk` / `pinyin_simp`）会显著增加部署时间与内存。
> 必须用 `scripts/measure_memory.sh` 记录前后对比；若安卓侧内存不可接受，
> 退路是 GBK 词库只在 `o` 键补丁下按需加载（与 Q9=C 仍兼容）。

---

## 8. Bench 与验收（Q16=B）

### 8.1 指标

| 指标 | 定义 | 目标 |
|---|---|---|
| **首选命中率** | bench 语料断句后，每句灌码，首位候选即正确结论的比例 | **不劣于 baseline，力争提升** |
| **平均候选位次** | 目标词在候选中的平均排名 | 下降 |
| **平均码长** | 达到正确候选所需击键数 | 不上升 |
| **空码率** | 灌完码后无候选的断句比例 | 下降（词库扩容的直接收益） |
| 部署时间 | `rime_deployer` 编译耗时 | 记录，不设阈值 |
| 内存占用 | `measure_memory.sh` | **安卓侧必须可接受** |

### 8.2 实现方式

- 用 `scripts/rime_tui.cc` 的 librime 接口包一层 `bench.py`（灌码 → 读候选 → 比对）。
- 语料：`bench/corpus.txt`。**M1 用占位语料**（Q27：中文维基百科 3–5 个条目摘录，约 1500 字，覆盖日常 / 技术 / 文学三段），
  README 与文件头注明来源与 CC BY-SA 4.0；你提供真实文本后**直接替换该文件**。
- **语料可替换，基线可重跑**（关键约束）：
  - `bench/baseline.json` 记录 `{corpus_sha256, git_tag, metrics}`。
  - M1 产物打 tag（如 `m1-baseline`），其 `dist/` 存为 CI artifact。
  - 换语料后，用 `m1-baseline` 的产物重跑 bench → 得到**同一语料下的新基线**，
    再与 M2 对比。**绝不拿不同语料的数字做跨版本比较**（那等于没测）。
- 每次 PR 由 `bench.yml` 输出对比表，若 `corpus_sha256` 与 baseline 不一致则**先重跑基线再比较**，
  **指标劣化则 PR 不可合并**。

---

## 9. 被占用编码清单（Q10=B / Q19）

`dicts/cloudkeytao.occupied.dict.yaml` 是唯一真相，格式：

```yaml
# 记录"因模式前缀而不可达"的编码，供 CI 断言与文档生成
# 字段：text / code / reason / reachable_via
那	a	prefix:a=整句连打	single 全码 / 反查
又	a	prefix:a=整句连打	single 全码 / 反查
氵	a	prefix:a=整句连打	反查
...
```

- 由 `scripts/gen-occupied-doc.py` 生成 `docs/occupied-codes.md`（人读表格）。
- CI 断言：**新增任何前缀模式时，若与清单冲突则 fail** —— 防止半年后再次踩同一个坑。

---

## 10. 里程碑与验收标准

### M1 · 骨架与基线（不改变任何手感）

**产出**
- repo 建好、上游 pin 到具体 commit、`flake.nix` devShell 可用
- `scripts/build.sh` 产出 `dist/rime/`，`cloudkeytao.schema.yaml` 合成成功
- `rime_deployer --build` 两平台（linux/android）编译通过
- fcitx5 里能选到「CloudKeyTao」并正常打字
- `bench.py` 跑通，产出 `bench/baseline.json`
- `dicts/cloudkeytao.occupied.dict.yaml` + `docs/occupied-codes.md` 生成
- `NixOS-Config` 改造完成：activation 脚本里的 `cp`/`sed`/`rm`/`register_lua` **全部删除**

**验收**：`keytao` 与 `cloudkeytao` 同时可选；两者打同一份文本输出一致（证明"原味"未被污染）。

---

### M2 · 词库与排序（痛点 (a) 的正解）

**产出**
- `merge-dicts.py`：≥4 码筛选 + danzi 全量 + 三套权重刻度归一 + 稳定排序
- `dicts/gen/` 生成约 80 万新词条
- bench 对比表（baseline vs M2）

**验收**（硬指标）
- 平均候选数（码长加权）**≤ 1.2**
- 6 码最大候选 **≤ 12**
- 简码（≤3 码）层条目数 **不增加**
- 首选命中率 **不劣于 baseline**，平均候选位次 **下降**
- `git diff` 只显示真实变化，重跑输出 byte-identical

---

### M3 · 反查与功能

**产出**
- `` ` `` 引导三合一反查（拼音 / 二分 / GBK）
- `'` 自造词、整句连打、重复上屏
- `?` 词库模糊查询、`0` 调频
- 安卓产物（同一份 `dist/`）

**验收**
- 三个反查场景各打 10 个样本字全部命中
- 内存增量记录（`measure_memory.sh`），安卓侧可接受
- 安卓端导入 zip 后与 Linux 输出一致（同码逐条比对脚本）

---

### M4 · 打磨与发布

- Q6c 工具集（`=` 计算器/单位换算/日期/UUID/密码）按需追加
- Q6g 文本加工面板按需
- 触屏专用 key_binder patch
- `release.yml` 出 `cloudkeytao-<ver>.zip` + README 授权声明
- 打字统计（Q12）另议

---

## 11. 风险与待办输入

| 风险 | 影响 | 缓解 |
|---|---|---|
| 授权链：星空键道 `default.nix` 写 `No explicit license`；xmjd6 **无 LICENSE 文件** | 你已决定：**不做授权审查，README 致谢即可**（Q26） | 发布前 README 写清致谢：吅吅大山（星空键道6）、星猫键道6 作者（词库来源）、rime-ice（词频）；标注"本仓库只含配置、词频加工与自研 lua" |
| schema 派生方式（复制改写 vs `__include`）语义不确定 | M1 阻塞 | M1 必须用 `rime_deployer` 实测；失败则改用显式全量 YAML + 注释说明差异 |
| rime-ice 词频对长尾词覆盖不足 | 部分 word 的 weight 落空 | 落空条目统一给"最低词频档"，并统计落空率 |
| 80 万词条的部署时间/内存 | 安卓侧体验 | M2 必须记录；不可接受则按码长分级削到 4 码以上再筛 |
| 三套权重刻度归一出错 | 单字/词候选顺序整体错位 | 管线内置断言 + bench 会立刻暴露 |

**当前输入状态**
1. `bench/corpus.txt`：M1 用**占位语料**（Q27），不阻塞开工；你后续提供真实文本时替换并重跑基线（机制见 §8.2）
2. `xmjd6-rere` 词库取用方式：CI 用 `fetchFromGitHub` 钉 commit（**默认采用**）

---

## 12. 下一步

确认本方案后，从 **M1** 开始。M1 完成前不碰词库、不碰功能。
