-- CloudKeyTao: rime.lua 入口
--
-- 上游的 rime.lua 被 scripts/build.sh 原样安装为 `lua/_upstream.lua`，
-- 因此这里只需 `require("_upstream")` 就能拿到上游的全部注册
-- （oboot_translator / keytao_filter / topup_processor / number_translator /
--   smart_2，外加 librime-lua 的 GC 调参）。
--
-- 这样做的好处：永远不需要编辑上游文件。
-- 旧方案在 NixOS activation 里 `sed -i` 改 nix store 里的 rime.lua，既静默又不可复现。

require("_upstream")

-- ── CloudKeyTao 自研模块 ────────────────────────────────────────────────────

-- emoji 延后过滤：让 emoji 候选排在正常候选之后
defer_emoji_filter = require("defer_emoji_filter")

-- [ / ] 取候选的首字 / 末字
select_character = require("select_character")

-- 造词：把选中的字拼成新词（见 add_phrase.lua 头部说明）
add_phrase = require("add_phrase")

-- 自定义短语优先：custom_phrase 的候选提到最前
promote_custom_phrase = require("promote_custom_phrase")

-- custom_phrase.txt 热更新，改文件后无需重新部署
custom_phrase_live = require("custom_phrase_live")

-- 快捷文本：/rq /sj /ts /unix /uuid /email 等
quick_text = require("quick_text")
