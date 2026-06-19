# 墨学书架（暂定名）

面向 HarmonyOS 平板的本地优先手写学习应用。

应用不直接导入 PDF。PDF 由 Codex、Claude 等 AI 工具在外部转换成符合
`ai.studybook` 协议的 `.studybook.zip` 学习包；应用负责校验、导入、阅读、
手写练习、复习与学习记录。

## 项目目录

```text
app/                         HarmonyOS ArkTS / ArkUI 应用
docs/
  specifications/           需求、概要、详细设计、接口 DTO、识别验收
  assets/mockups/            功能效果图
packages/
  studybook-schema/          学习包 JSON Schema 与协议
samples/                     示例学习包
tools/
  mockup-generator/          效果图生成源文件
  studybook-validator/       学习包校验工具
```

开发前必须阅读根目录的 `CLAUDE.md`、`docs/specifications/` 下的正式文档，
以及 `docs/已知冲突与裁决记录.md`。
