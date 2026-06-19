# 交接说明（HANDOFF）

| 项目 | 内容 |
|---|---|
| 文档 | 墨学书架 规格文档**评审整改**交接书 |
| 更新日期 | 2026-06-19 |
| 当前阶段 | 评审 73 项整改，Batch D1/D2 已完成，D3~D7 待续 |
| 接手者 | 其他同事 / AI（Codex 或新的 Claude 会话） |

> **第一步永远是读这份 HANDOFF，再读 `CLAUDE.md` 与 `docs/规格评审报告-v1.md`。**
> 本仓库当前是**文档整改**工作，不是写代码（`app/`、`samples/`、`tools/studybook-validator/` 仍是空壳）。

---

## 1. 这是在做什么

对一套已有的设计文档（需求/概要/详细/协议/Schema）做了一轮深度评审，产出 **73 条发现（R-001~R-073）**，
现在正按批次**逐条整改文档本身**。6 条阻断项已由前一位（Codex）修完，本次接续把其余整改完。

## 2. 关键文件地图

| 文件 | 作用 | 谁维护 |
|---|---|---|
| `docs/规格评审报告-v1.md` | **工作清单**：73 条，每条含 位置/问题/影响/建议修复/核验校正 | 只读基准 |
| `docs/.review/audit-findings.json` | **原文证据**：每条的 evidence 原文摘录 + 核验理由（verifyReason/verifyNote）。做整改与 D7 一致性审计时对照用 | 只读基准 |
| `docs/已知冲突与裁决记录.md`（ADR） | **进度 + 裁决**：已完成批次逐条 disposition，末尾「尚未处理」列剩余 | **每批必须更新** |
| `docs/specifications/06-协议到数据库映射规范.md` | 协议→DB 字段映射/派生/去重/错误词表 **唯一真值** | 评审新增 |
| `docs/specifications/04-接口与DTO契约.md` | 跨模块 DTO/接口唯一真值 | 阻断期新增 |
| `docs/specifications/05-手写识别验收规范.md` | 90% 识别验收数据集与公式 | 阻断期新增 |
| `docs/specifications/01~03` | SRS / HLD / LLD 三件套（整改主战场是 03-LLD） | 整改对象 |
| `packages/studybook-schema/*.json` | manifest/book/chapter JSON Schema | 整改对象 |

## 3. Git 状态与如何回看

- 仓库已 `git init`，工作区在 `D:\worksace\other\books`，尚未配远端。
- 提交链（每批一个 commit，可逐批 diff）：

  ```text
  838a6cd  基线快照（Codex 修完 6 条阻断后的状态）
  268841d  Batch D1 数据流 R-002~R-012
  bb834d8  Batch D2 状态机与事务 R-013~R-024
  ```

- 看某批改了什么：`git -C <repo> show <hash> --stat` 或 `git diff 838a6cd..HEAD`。
- **接手后第一件事**：`git add -A && git commit` 把 `docs/.review/`、本 `HANDOFF.md` 先提交固化。

## 4. 批次计划与进度

整改按下列 7 批顺序推进（评审报告 §3 的修复顺序）：

| 批次 | 范围 | R-### | 状态 |
|---|---|---|---|
| ① D1 数据流 | 协议→DB 映射/派生/写入路径 | R-002~R-012 | ✅ 已完成（commit 268841d） |
| ② D2 状态机与事务 | 取消/重试/升级/后台/恢复/多空聚合/删除导出 | R-013~R-024 | ✅ 已完成（commit bb834d8） |
| ③ D3 接口与服务契约 | 接口/DTO | R-050~R-061 | ⬜ **下一批**，多数已被 04 契约解决，以**核销**为主 |
| ④ D4 数据库约束 | 枚举 NOT NULL/唯一/ReDoS/软删/缺失 Schema | R-038~R-049 | ⬜ 待办 |
| ⑤ D5 页面与交互约束 | 路由/状态/单位/渲染映射 | R-025~R-037 中页面/歧义类 | ⬜ 待办 |
| ⑥ D6 测试/验收/NFR | 可追溯/可执行测试/术语/统计公式 | R-062~R-073 | ⬜ 待办 |
| ⑦ 全量一致性审计 | 跨文档复查、版本号同步、CHANGELOG | 全部 | ⬜ 最后做 |

> R-025~R-037 属评审的「D3 描述清晰度」维度，整改时按性质拆入 ④/⑤（DB 类入 D4，页面/歧义类入 D5）。

## 5. 每批标准工作流（务必照做）

1. 读评审报告里该批每条的 **「核验校正」**——33 条已下修严重度或纠正引用，**按校正口径处理，别按原始描述**。
2. 用 `docs/.review/audit-findings.json` 对照原文证据，先确认问题**是否仍存在**（部分可能已被前序批次/Codex 顺带解决 → 直接核销，不重做）。
3. 改文档（主要是 `03-LLD` 与 schema）。字段级映射一律以《06 映射规范》为准。
4. 改完 schema **必跑 JSON 校验**：`python -c "import json;json.load(open('<file>',encoding='utf-8'))"`。
5. 在 ADR（`docs/已知冲突与裁决记录.md`）追加该批 disposition，并更新「尚未处理」。
6. **单独 commit**：`fix(docs): 评审 Batch <X> ...`，message 末尾保留：

   ```text
   Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
   ```

## 6. 必须遵守的约定 / 铁律

- **解决而非降级**：禁止用「删字段/删功能/占位」来消矛盾。唯一例外是 R-063（见 §7），且已被评审认可、仍待业主复核。
- 全程**中文**；每条整改保留 **R-### 可追溯**交叉引用，并核对 R-### 与评审报告标题一致（D2 曾发现 R-016/R-017 引用标反，已纠正——务必核对）。
- 文档优先级链（`CLAUDE.md` §3）：`CLAUDE.md > 01-SRS > 02-HLD > 03-LLD > 协议/Schema > 源码注释`；冲突按高优先级裁决并登记。
- 若接手者是 Claude：**一次任务子 agent 总数 ≤ 7**（业主硬性要求，token 敏感，ultracode 也服从）。

## 7. ⚠️ 待业主拍板的开放项（不能默认）

- **R-063：非手写题型（choice/true-false/match/order-words）**——Codex 已选「v1 砍掉、白名单移除 + IMP-020 阻断」。
  这关闭了 R-004、R-019。但与「解决而非降级」铁律有张力。**业主尚未最终确认是『保持砍掉』还是『补齐四种题型的设计』**。
  接手前请向业主确认；若改为补齐，需回滚相关 schema/LLD/协议改动并补全作答-判分-存储链路。

## 8. 防重复：已完成 / 已核销清单

- **6 条阻断全部完成**：R-001(复习卡创建)、R-013(解压时序)、R-025(完成度公式)、R-050(DTO 契约)、R-062(90% 验收)、R-063(题型范围)。
- **被顺带关闭**：R-002(flashcard 落库)、R-004 & R-019(非手写题型，随 R-063)。
- **D1/D2 已整改**：R-003/005/006/007/008/009/010/011/012/014/015/016/017/018/020/021/022/023/024、R-029(contentVersion)。
- 接手时对以上项只需**核验，不重做**。

## 9. 滚到后续批次的待落地项（别遗漏）

| 待办 | 落地批次 | 说明 |
|---|---|---|
| `exercises.grading_options_json` 列 | D4 | 《06》§4.1 已声明，需写进 LLD §3.8 |
| `content_review_flags` 表 DDL | D4 | 《06》§8 已定义结构，需写进 LLD §3 新小节 |
| `bullet-list`/`audio-text` 渲染组件 | D5 | 协议 §5.2 要求支持，LLD §6.5 映射表缺这两项 |

## 10. 环境备注

- 平台 Windows；仓库 `D:\worksace\other\books`。
- 用 Python 打印中文需 `PYTHONIOENCODING=utf-8`，否则控制台报编码错。
- git 在 Git Bash 下用 `git -C "D:/worksace/other/books" ...` 避免 `cd` 触发权限弹窗。
- 行尾 LF→CRLF 警告可忽略（Windows git 默认行为）。

## 11. 接手者的下一步

1. 提交 `docs/.review/` 与本 `HANDOFF.md`。
2. 向业主确认 §7 的 R-063 决定。
3. 开始 **Batch ③ D3 接口与服务契约**：逐条把 R-050~R-061 与 `04-接口与DTO契约.md` 对照，已满足的在 ADR 标「已由 04 契约解决」核销，残留的补齐。
