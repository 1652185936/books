# Ralph 迭代指令 — 墨学书架 HarmonyOS app 实现（支持并行提速）

你在墨学书架仓库的 `ralph` 分支（隔离 git worktree）里**自主实现第一版应用**。
最终目标：按 `docs/specifications/01-需求规格说明书.md`（及 02 HLD / 03 LLD / 04 契约 / 05 验收 / 06 映射）完整实现 ArkTS + ArkUI 平板应用。

## 本轮闭环（可串行 1 条，或并行多条独立功能）

1. 读 `CLAUDE.md`（项目最高约束，必须服从）、`HANDOFF.md`、`BACKLOG.md`。
2. 从 `BACKLOG.md` 选「未勾选 `[ ]`、依赖项均已 `[x]`」的条目，按下列模式之一推进：
   - **串行模式（默认，用于有依赖链或会改共享文件的条目）**：一轮只做最靠前 1 条。导入内核 P1-3/4/5、阶段 0、阶段 3 的整合性条目一律串行。
   - **并行模式（feature 阶段提速）**：当有 **≥2 条彼此独立**的功能切片可做时（F01~F12 各自有独立的 Repository/Service/ViewModel/Page 文件、互不依赖），一轮最多取 **7 条**，按下「## 并行开发规则」用子 agent 同步实现。
   - 若所有条目都 `[x]`（或仅剩 BLOCKED）→ **创建空文件 `.ralph/STOP` 并立即结束本轮**。

## 并行开发规则（避免互相覆盖 / 合并冲突）

仅当本轮选了多条独立 feature 时启用：

1. **在一条消息里同时发起 ≤7 个子 agent**（每个负责 1 条 feature），真正并行。**每轮 fan-out ≤7（业主已授权上限 7），同时并发子 agent 不超过 7。** 子 agent 越多、主 agent 整合共享文件的负担越大，按本轮独立 feature 的真实数量取，宁稳勿滥。
2. **文件隔离**：每个子 agent **只新建/修改它那条 feature 自己的文件**（如 `ets/repositories/<Feat>Repository.ets`、`ets/services/<Feat>Service.ets`、`ets/viewmodels/<Feat>VM.ets`、`ets/pages/<feat>/*.ets`）。
3. **子 agent 绝不碰共享文件**：`resources/{base,zh_CN,en_US}/element/string.json`、`resources/base/profile/route_map.json`、`utils/Routes.ets`、`database/migrations/*`、任何中央注册/DI 文件。它们**改不了共享文件，只能在返回里申报需求**——返回：①新建文件清单；②需要的资源键（`key → 中文 / 英文`）；③需要的路由/注册接线说明。
4. **主 agent 负责整合**：所有子 agent 完成后，由你（主 agent）**串行地**把申报的资源键并入三份 `string.json`、接线路由/注册（共享文件只有你一个写入者，杜绝并发覆盖），然后统一自验证。
5. **若 feature 之间共享文件过多、并行协调有风险 → 退回串行**，一条一条做更稳。

## 实现约束（每条都遵守）
- 技术栈 ArkTS + ArkUI；ArkTS 开严格类型，禁止无理由 `any`。
- 优先级链：`CLAUDE.md > 01-SRS > 02-HLD > 03-LLD > 04 契约/Schema > 06 映射 > 源码注释`。
- 先找需求编号 `FR-Fxx` + 验收，再按 LLD 的 DB 设计/页面约束实现；先数据层与可测业务逻辑，再 ArkUI 页面。
- 字段映射以《06》、跨模块 DTO 以《04 契约》为唯一真值；不自造结构。
- **解决而非降级**：禁止删字段/功能/题型；保留全部九种题型（R-063，非手写四种占位）。
- 页面不直接执行 SQL，必须经 Repository；ZIP 导入/解压/DB 写入在事务/可回滚流程内。
- 用户可见文本进资源文件（LLD §3.14B），不硬编码；日志不输出完整正文/笔迹/敏感路径。

## 自验证（用环境里可用的手段，能跑就跑）
- 改到 JSON/Schema → `python -c "import json;json.load(open('<f>',encoding='utf-8'))"`。
- 有可用类型检查/构建/单测就跑并确保通过。
- HarmonyOS 工具链（hvigor/DevEco）不可用 → 至少保证代码自洽、引用到的类型/接口/资源键都已定义，并在 BACKLOG 该条后注明「未编译验证：缺 SDK」。

## 提交与登记
- **每条完成的 feature 各做一个聚焦 commit**（Conventional Commits 中文标题，正文含需求编号；末尾保留 `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`）；**不要 push**。
- 每条在 `BACKLOG.md` 把 `[ ]` 改 `[x]`，并在文末「## 日志」追加 `- [x] <条目> @<commit短哈希> — <一句话>`。
- 卡住/无法满足验收：**不硬改、不砍需求**。在该条下追加 `> BLOCKED: <原因>`，跳过它、结束本轮。

## 绝不修改（禁改清单）
- `CHANGELOG.md`、`docs/specifications/README.md`、`docs/功能效果图索引.md`、`docs/specifications/07-*`、`docs/assets/mockups/F13-*`、`docs/.review/`。
- 已定稿的 `docs/specifications/*` 规格：除非发现真实冲突——先在 `docs/已知冲突与裁决记录.md` 记录并按优先级链裁决，不擅改规格语义或字段语义。
- 不删旧迁移、不清空用户数据；数据库升级只新增迁移。
