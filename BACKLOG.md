# 墨学书架 — 实现 Backlog（Ralph 自主迭代）

最终目标：按 `docs/specifications/` 规格完整实现第一版 HarmonyOS 平板应用（ArkTS + ArkUI）。
顺序遵循 CLAUDE.md §4 开发流程：先数据层与可测业务逻辑，再 ArkUI 页面，再测试。
每条尽量是「一轮可完成 + 可验证」的粒度。依赖靠顺序表达（靠前的先做）。

## 阶段 0 — 工程与基础设施
- [x] P0-1 HarmonyOS 工程脚手架：`app/` 下建 DevEco/hvigor 工程（module.json5、app.json5、ArkTS 严格类型配置、目录骨架 ets/{pages,viewmodel,service,repository,db,model,resource,utils}），可被 hvigor 识别。
  > 备注：目录骨架按 LLD §1.2 真值建（pages/components/viewmodels/domain/repositories/services/database/storage/recognition/utils；资源置 `entry/src/main/resources/`，非 ets 内），覆盖 BACKLOG 的非正式命名。未编译验证：缺 HarmonyOS SDK / hvigor，仅做引用自洽与 JSON 校验。
- [x] P0-2 通用类型与 DTO：按《04 契约》§1 定义 `Id/EpochMs/JsonObject/PageRequest/PageResult/AppError`，并为各域 DTO 建 ArkTS model 文件（导入/书籍内容/进度/手写识别/练习判分/复习/批注/错题统计/设置/备份），与 04 字面一致。
  > 落地：`entry/src/main/ets/domain/entities/` 下 11 个文件（common/import/content/progress/handwriting/exercise/review/annotation/wrongbook-stats/settings/backup），逐字段对齐 04 §1~§11（含全部 19 个 Repository/Service/Engine 接口契约）。
  > ArkTS 适配（字段集/语义不变）：交叉类型 `&`→`interface extends`（BookDetail/WrongItemDetail）；索引访问 `ReviewCard['state']`/`ExerciseDetail['gradingOptions']`→具名类型 `ReviewCardState`/`GradingOptions`；联合内联支与内联返回对象拆具名接口（ImportPhaseEvent/RecognitionSuccess/RecognitionFailure/RelocationList/WeakPoint/DailyStat/StrokeCanvas/ContinueTarget）。
  > 验证：11 文件经独立 `tsc --strict --noEmit` 交叉核验通过（跨文件 import/导出、联合、extends、泛型自洽）。未编译验证（缺 HarmonyOS SDK）两处：①`JsonObject` 递归 Record 取值（保持 04 字面，tsc 判 TS2456 为 ArkTS↔tsc 已知分歧，详见文件头注释）；②`SettingsService.get/set` 的泛型索引访问返回 `SettingsValueMap[K]`（保持 04 字面，待 F12 用 SDK 实测，必要时按优先级链登记裁决）。
- [x] P0-3 数据库迁移 V001：按 LLD §3 全部表与索引（books…content_review_flags、§3.25）写 `V001__initial.sql`，含所有 NOT NULL/CHECK/UNIQUE/FK；relationalStore 封装 + 迁移执行器（迁移表、单调递增、只执行一次）。
  > 落地：`resources/rawfile/migrations/V001__initial.sql`（22 业务表 + 17 显式索引，逐表对齐 §3.3~§3.25）+ `ets/database/{SqlScript,MigrationRunner,Database}.ets` + `ets/database/migrations/MigrationRegistry.ets`。元数据表 `db_meta`(§3.2)/`schema_migrations`(迁移表) 由执行器 `CREATE TABLE IF NOT EXISTS` 引导。
  > 约束亮点：枚举全 NOT NULL CHECK（R-039）；accepted_answers 主答案部分唯一索引；bookmarks 章节/块级部分唯一（R-012）；handwriting_records 三态互斥 XOR + 对应 CHECK（R-041）；exercises 九种题型 CHECK（保留非手写四种，R-063）；recognition_error_code 形式化 CHECK（R-057）。
  > 自验证：V001 全量 DDL 经 SQLite（relationalStore 底座）解析建表通过（24 表）+ 约束冒烟测试（FK/枚举/长度/题型/主答案/笔迹 XOR/收藏唯一/版本唯一）全通过。未编译验证：缺 HarmonyOS SDK，ArkTS 侧仅引用自洽核查（relationalStore/resourceManager/TextDecoder 以 API 12 为准）。
- [x] P0-4 Repository 基类与事务封装：统一 Repository 接口约定（页面不碰 SQL）、事务/可回滚封装、`AppError` 领域错误。
  > 落地三件：①`utils/AppErrors.ets` 领域错误工厂——固化 §3.14A error_code→资源键稳定映射（25 条逐行核验一致）+ `DB_*` 通用码兜底 `state.error`；`create/from/isAppError/sanitizeDetail`，detail 脱敏 ≤1000（04 §1），不抛裸字符串。②`database/Database.ets` 增 `withTransaction<T>`/`TransactionWork<T>`——单事务执行、失败整体 `rollBack` 并归一为 `DB_TRANSACTION_FAILED`（LLD §8，relationalStore 经典事务不可重入约定写入注释）。③`repositories/BaseRepository.ets` 抽象基类——`store` 仅 protected 可见（页面不碰 SQL，CLAUDE.md §5）、`queryList/querySingle`（ResultSet finally 关闭、异常归一 `DB_QUERY_FAILED`）、`runInTransaction`、`wrapError`。
  > 自验证：§3.14A 映射经 Python 与规格逐行比对 PASS（25/25 一致、无缺漏无多出）；引用自洽核查通过（TransactionWork/AppErrors/AppError 及 relationalStore API 沿用 P0-3 基线）。未编译验证：缺 HarmonyOS SDK，relationalStore querySql/ResultSet/事务 API 以 API 12 为准。
- [x] P0-5 i18n 资源骨架：`resources/{base,zh_CN,en_US}/element/string.json`；按 LLD §3.14A 落 error_code→资源键映射的全部键中英文文案（§3.14B 文案表）。
  > 落地：三份 `app/entry/src/main/resources/{base,zh_CN,en_US}/element/string.json`——25 条 §3.14A 键（20 IMP-* + 5 识别码）+ §3.14B 通用键 `action_confirm`/`state_loading`/`state_empty`/`state_error`；base=中文基线（含原脚手架键）、zh_CN=中文、en_US=英文。§3.14B 给定 6 条文案（invalidZip/hashMismatch/recognition.timeout/recognition.unavailable/action.confirm/state.empty）逐字一致，其余按口径落盘补齐。
  > 实现期冲突裁决（已登记 ADR「实现期冲突：i18n 资源键命名」）：§3.14B 点分键与 HarmonyOS `restool` 资源名规则 `[a-zA-Z0-9_]`/`$r('app.string.NAME')` 引用语法冲突。按优先级链（CLAUDE.md §2.1 ArkTS/ArkUI 最高）裁决：点分键保留为 i18n 逻辑键真值（§3.14A 不改），物理资源名用确定性 `.`→`_` 转写；`AppErrors.physicalKeyFor` 单点桥接（`error.import.invalidZip`→`error_import_invalidZip`）。解决而非降级、无字段/语义删改。
  > 自验证：三份 JSON 经 Python `json.load` 解析通过；§3.14A 全 25 键在三文件齐备、无 restool 非法资源名、规范给定 6 条文案逐字一致（脚本核验 PASS）。未编译验证：缺 HarmonyOS SDK，`restool` 命名规则以官方文档为准（已 context7 核实）、`$r` 引用桥接待 SDK 编译实测。
- [ ] P0-6 路由骨架：按 LLD §6 各页面路由（含 §6.13 `from`/`bookId`/`range` 约定）建 Navigation 路由表与占位页。

## 阶段 1 — 导入内核（F02/F03 的核心，多功能依赖）
- [ ] P1-1 ZIP 安全校验：路径穿越/条目数/大小/压缩比/扩展名（LLD §2.1、IMP-001~004），不解压先检查。
- [ ] P1-2 内置 JSON Schema 校验器：用 `packages/studybook-schema/` 的 manifest/book/chapter/report/checksums 校验暂存文件；忽略包内 schemas/（LLD §2.4 step8）。
- [ ] P1-3 导入状态机与暂存区：LLD §2.3/§2.4 状态机、隔离暂存、SHA-256 比对（§2.4 step7）、IMP-* 错误码与 §3.14A 文案。
- [ ] P1-4 导入事务与索引落库：协议→DB 映射（《06》全文）、章节/小节/内容块/练习/空位/答案/复习卡/复核标记落库、chapter_count 事务内重算；原子提升 + 提交（§2.4 step11-13）。
- [ ] P1-5 取消/重试/后台/重启恢复 + 升级子流程：LLD §2.6/§2.7（cancel 边界、可重试分类、awaiting_confirmation 24h、升级 snapshot/promote/restore）。

## 阶段 2 — 各功能垂直切片（Repository → Service → ViewModel → 页面 → 自验）
- [ ] F01 书架页：BooksRepository.list + 书架页 + 重启恢复 continueTarget（FR-F01，LLD §6.1）。
- [ ] F02 导入选择页：ImportService.create + 选择/空间检查页（FR-F02，LLD §6.2）。
- [ ] F03 校验结果页：runValidation 进度流 + 可读失败原因 + 回滚（FR-F03，LLD §6.3）。
- [ ] F04 目录页：listChapters + searchChapters(章节级) + 完成度展示（FR-F04，LLD §6.4）。
- [ ] F05 章节讲解页：getChapter + 11 种 block 渲染组件（含 BulletList/AudioTextBlock，§6.5 映射表）+ 默认小节/空 sections（R-034）。
- [ ] F06 手写练习页：笔迹采集/即时墨迹/防误触、blank 多空、draft 快照（§4.1/§6.6），单位换算 emToVp（§1.3）。
- [ ] F07 识别与判分页：HandwritingRecognizer 封装 + RecognitionHandle/取消 + GradingEngine 纯函数 + GradingService 编排 + 逐空 perBlank（§4.2/§4.4/§4.5）；识别失败/降级（R-065）。
- [ ] F08 批注页：AnnotationRepository/Service（笔记/高亮/收藏 + 自动保存 + 退出落盘 + 重定位），handwriting_records 三态（§3.15/§6.8）。
- [ ] F09 复习页：ReviewScheduler（间隔算法 §5 + applyRating + getTodaySummary + 会话去重）+ 复习页（FR-F09，LLD §6.9）。
- [ ] F10 错题本页：WrongBookRepository(query/getDetail/listForBatch/markMastered 不覆盖历史) + 筛选/重做/批量页（FR-F10，§6.10）。
- [ ] F11 学习统计页：StatisticsService(recordEvent/getMetrics/recompute) + 统计口径(§3.13.1/§3.13A) + 图表+文本摘要（FR-F11，§6.11）。
- [ ] F12 设置与数据页：SettingsService 键级校验 + 导出/恢复(BackupService 兼容判定) + 清缓存白名单 + 两阶段删除(§8.1)（FR-F12，§6.12）。

## 阶段 3 — 非功能、安全与收尾
- [ ] P3-1 regex 判分 ReDoS 防护：导入期静态校验 + 运行期输入上限/50ms 硬超时降级（LLD §3.11、HLD §11）。
- [ ] P3-2 缓存策略与文件版本：LRU/容量(§9A)、笔迹文件 version 兼容、备份 formatVersion 兼容判定。
- [ ] P3-3 NFR 落实核对：性能/可靠性/安全/无障碍/兼容性（SRS §8 NFR-P/R/S/A/C）逐条对照实现。
- [ ] P3-4 测试用例：实现 LLD §11 的 TC-U-001~008 单元测试 + TC-I-001~007 集成测试（能在环境里跑的优先）。
- [ ] P3-5 功能完成矩阵：新建/更新「功能完成矩阵」文档，对照 SRS §9 与 §10 总体验收逐项打勾，列出未编译验证项。

## 日志
（每轮在此追加：`- [x] <条目> @<commit短哈希> — <一句话>`）
- [x] P0-1 HarmonyOS 工程脚手架 @41bea58 — 补齐 AppScope/app.json5、entry module.json5/build-profile/oh-package/hvigorfile/obfuscation、EntryAbility 与 pages/Index 入口、base 资源（string/color/main_pages）及 LLD §1.2 ets 目录骨架（.gitkeep 占位）。
- [x] P0-2 通用类型与 DTO @556db45 — `domain/entities/` 11 个 ArkTS 模型对齐《04》§1~§11（本轮恢复提交：上一轮 PowerShell 工具异常落盘未提交）。
- [x] P0-3 数据库迁移 V001 @531702a — V001__initial.sql（22 业务表 + 17 索引，§3.3~§3.25）+ SqlScript/MigrationRunner/Database/MigrationRegistry；DDL 经 SQLite 解析建表 + 约束冒烟测试全通过，relationalStore 封装与迁移执行器（迁移表/单调递增/单事务/只执行一次/可回滚）就绪。
- [x] P0-2 通用类型与 DTO @556db45 — 在 `domain/entities/` 新增 11 个 ArkTS 模型文件对齐《04》§1~§11（DTO + 19 接口契约），经 `tsc --strict --noEmit` 交叉核验通过。（提交在 ralph 本轮恢复：上一轮 PowerShell 工具异常 Exit 66 落盘未提交，本轮补提交为 @556db45。）
- [x] P0-4 Repository 基类与事务封装 @1d9c2fb — 新增 `utils/AppErrors.ets`（§3.14A 码→资源键映射 25 条逐行一致 + 领域错误工厂/脱敏）、`repositories/BaseRepository.ets`（页面不碰 SQL、ResultSet 安全遍历、查询异常归一），并给 `database/Database.ets` 增 `withTransaction` 事务/可回滚封装；映射经 Python 与规格逐行比对 PASS。
- [x] P0-5 i18n 资源骨架 @pending — 三份 `resources/{base,zh_CN,en_US}/element/string.json` 落 §3.14A 全 25 键 + §3.14B 4 通用键中英文文案；登记并裁决 i18n 点分键 ↔ HarmonyOS `restool` 命名实现期冲突（保留逻辑键真值、物理名 `.`→`_` 转写、`AppErrors.physicalKeyFor` 桥接）；JSON 解析/全键齐备/命名合法/给定文案逐字一致核验 PASS。
