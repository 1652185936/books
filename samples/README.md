# 示例学习包（导入测试夹具）

供导入流程测试用的 `.studybook.zip` 夹具，符合 `ai.studybook` 协议与 `packages/studybook-schema/` 的 Schema。
由 `tools/studybook-validator/build_samples.py` 生成、`selftest.py` 回归校验。

| 包 | 来源书目 | 章节 | 题型覆盖 |
|---|---|---|---|
| `essential-grammar-in-use-3e.studybook.zip` | 《剑桥初级英语语法》Essential Grammar in Use 3e（Raymond Murphy，外研社·剑桥，328 页/115 单元） | 7（lesson/review/answer-key/index） | fill-blank / multi-blank / short-answer 手写题 + 1 个 `choice` 非手写题（占位，验证 R-063 保留）+ flashcards + 1 张原创插图 |
| `new-concept-english-1-guide.studybook.zip` | 《新概念英语1·同步导学》（251 页） | 3 | fill-blank 手写题 |

说明：
- 内容为**依据真实书目结构原创/重构**的最小代表性样例（含协议 §6 的 `is drinking` 经典例题、弯/直撇号变体以验证去重 R-040/R-035）；**不含**原 PDF、整本受版权内容或翻拍插图（遵守 CLAUDE.md 与协议 §7）。
- `index` 章节 `sections=[]`，用于验证空小节导入路径（R-034）。
- Murphy 包含一条 `ai-inferred` 答案并进 `report.reviewQueue`，用于验证 IMP-015 复核标记路径。
- 应用本身不解析 PDF；PDF→studybook 由外部生成器完成（本夹具即由该流程产出）。
