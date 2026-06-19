# StudyBook Validator（离线参考校验器）

在电脑端离线校验 `.studybook.zip` 是否能被应用导入。**镜像 LLD §2.4 导入校验链 + §2.5 IMP-* 错误码**，供测试/CI 用；应用端的 ArkTS 导入校验必须执行等价检查，不能完全信任电脑端结果。

## 文件
- `validate.py` — 参考校验器。逐项执行：ZIP 安全（IMP-001~004）→ 必需文件/解析（IMP-005/007）→ 主版本白名单（IMP-006）→ 5 份内置 JSON Schema 校验（IMP-008）→ SHA-256 比对（IMP-009）→ 业务校验（toc 引用 IMP-010 / id·order·chapterCount 一致 IMP-011 / 手写题答案 IMP-012 / 题型九种白名单 IMP-020）→ IMP-015 复核警告。
- `build_samples.py` — 从真实书目元数据构建 `samples/` 下两个夹具包（可复现）。
- `selftest.py` — 正向（样例应通过）+ 负向（7 种破坏分别被对应 IMP 码拒绝）回归测试。

## 用法
```bash
# 校验单个包（Schema 取自 packages/studybook-schema/）
python tools/studybook-validator/validate.py samples/essential-grammar-in-use-3e.studybook.zip

# 重新生成样例夹具
python tools/studybook-validator/build_samples.py

# 跑正向+负向自测（退出码 0 = 全绿）
python tools/studybook-validator/selftest.py
```
依赖：`jsonschema`（Schema 校验）、`pillow`（生成原创插图，缺失时自动跳过插图）。
