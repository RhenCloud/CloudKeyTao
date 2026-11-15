# CloudKeyTao 当前架构

> 本文描述仓库当前实现。历史方案和已废弃决策见 `plan/`，不要将其当作当前行为规范。

## 目标

CloudKeyTao 是键道 6 的薄覆盖层：不修改韵母键位、辅助码体系和顶功规则，主要扩展词库、候选排序、反查和 Lua 工具。

## 构建链路

`scripts/build.sh` 是唯一产物入口：

1. 从 Nix flake pin 的 KeyTao 和 xmjd6 输入复制只读源文件；
2. 注入 CloudKeyTao 的 Lua、custom patch 和词库；
3. 生成 xmjd6 长尾词库与三张反查词库；
4. 将上游表名归一为 `cloudkeytao.*`；
5. 内联生成唯一的 `cloudkeytao.schema.yaml`；
6. 删除其他方案并对最终产物执行结构断言。

最终产物是一个自洽的 Rime 用户目录，菜单中只出现 `cloudkeytao`。

## 反查

三个反查 translator 共用 `` ` `` 前缀：

- `` `dao ``：拼音；
- `` `hr ``：二分拆字；
- `` `wwx ``：GBK / 生僻字。

反查词库不进入主词库的 `import_tables`，而是通过 `schema/dependencies` 声明为部署依赖，并由 `scripts/runtime-test.sh` 验证运行时确实能返回候选。

## 质量门禁

`scripts/check-all.sh` 依次执行：

- Bash、Python、Lua 语法检查；
- ShellCheck、Ruff、actionlint（工具存在时）；
- 构建和结构断言；
- `rime_deployer` 真编译；
- 占用清单和 bench 检查；
- 两次构建幂等性检查；
- librime 运行时回归测试。

运行时测试覆盖普通输入、三种反查和快捷文本 `/rq`。部署脚本同时检查 `rime_deployer` 的退出码与错误日志，避免“有错误但生成了部分 bin”被误判为成功。

## 上游升级

上游版本在 `flake.nix` / `flake.lock` 中固定。`upstream-sync.yml` 只创建升级 PR，不自动合并。升级后必须检查：

- `scripts/check-all.sh` 是否通过；
- bench 是否退化；
- 运行时反查和 Lua 功能是否仍然有候选；
- 产物是否仍然只有一个方案。
