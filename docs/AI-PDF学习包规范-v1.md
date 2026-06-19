# AI PDF 学习包规范 v1.0

本规范定义一种可由 Codex、Claude 或其他具备 PDF/OCR 能力的 AI 生成，并可直接导入鸿蒙学习应用的 ZIP 学习包。

目标不是保存 PDF 页面，而是把书籍转换为可导航、可搜索、可练习、可手写判分的结构化课程数据。

## 1. 文件名与 ZIP 根目录

推荐文件名：

`<book-id>.studybook.zip`

ZIP 解压后必须直接看到以下内容，不能再套一层同名文件夹：

```text
manifest.json
book.json
report.json
checksums.json
chapters/
  unit-001.json
  unit-002.json
  ...
assets/
  cover.webp
  illustrations/
    unit-001-01.webp
schemas/
  manifest.schema.json
  book.schema.json
  chapter.schema.json
```

禁止放入原始 PDF、可执行文件、脚本、绝对路径或包含 `../` 的路径。

## 2. 通用技术要求

- ZIP 格式：标准 ZIP/Deflate。
- JSON 编码：UTF-8，无 BOM。
- JSON 文件不能包含注释、尾随逗号、NaN 或 Infinity。
- 所有 ID 在整本书中唯一，使用小写英文、数字和连字符。
- 所有文件引用均为 ZIP 内相对路径，路径分隔符使用 `/`。
- 页码统一使用 1 起始的 PDF 文件页序号。
- 中文语言代码使用 `zh-CN`，英文使用 `en`。
- 时间使用 ISO 8601 UTC，例如 `2026-06-19T12:00:00Z`。
- 图片使用 WebP、PNG 或 JPEG；优先 WebP。
- 不得把整页扫描图当作课程正文。
- 不得凭空补写书中不存在的知识点、例句或答案。
- OCR 不确定内容必须进入 `report.json` 的人工复核队列。

## 3. manifest.json

它是应用导入学习包时读取的第一个文件。

```json
{
  "format": "ai.studybook",
  "formatVersion": "1.0.0",
  "contentVersion": "1.0.0",
  "packageId": "essential-grammar-in-use-zh-3e",
  "createdAt": "2026-06-19T12:00:00Z",
  "generator": {
    "name": "Codex",
    "model": "model-name"
  },
  "entry": "book.json",
  "contentRoot": "chapters",
  "assetRoot": "assets",
  "book": {
    "id": "essential-grammar-in-use-zh-3e",
    "title": "剑桥初级英语语法",
    "subtitle": "Essential Grammar in Use",
    "authors": ["Raymond Murphy"],
    "languages": ["zh-CN", "en"],
    "cover": "assets/cover.webp",
    "chapterCount": 115
  },
  "checksums": "checksums.json"
}
```

`contentVersion` 是内容版本（语义化版本），与 `formatVersion` 相互独立：`formatVersion` 决定协议主版本兼容性（IMP-006 白名单），`contentVersion` 是去重与升级判定键。应用按 `packageId + contentVersion` 识别“重复导入”与“新版本覆盖”，并映射到 `books.content_version`（见《06-协议到数据库映射规范》§1）。

## 4. book.json

保存书籍资料和完整目录。应用通过 `toc[].file` 按需加载章节。

```json
{
  "schemaVersion": "1.0.0",
  "id": "essential-grammar-in-use-zh-3e",
  "title": "剑桥初级英语语法",
  "subtitle": "Essential Grammar in Use",
  "authors": ["Raymond Murphy"],
  "description": "面向初级英语学习者的语法课程。",
  "languages": ["zh-CN", "en"],
  "cover": "assets/cover.webp",
  "source": {
    "type": "pdf",
    "originalFileName": "source.pdf",
    "pdfPageCount": 328,
    "isScanned": true
  },
  "defaultChapterId": "unit-001",
  "toc": [
    {
      "id": "unit-001",
      "order": 1,
      "kind": "lesson",
      "title": "am / is / are",
      "titleZh": "系动词 be",
      "file": "chapters/unit-001.json",
      "sourcePages": [16, 17],
      "estimatedMinutes": 15
    }
  ]
}
```

目录必须完整、顺序正确。附录、答案、索引可以使用以下 `kind`：

- `lesson`
- `review`
- `appendix`
- `answer-key`
- `index`

## 5. 章节 JSON

原则上一个教学单元对应一个 JSON。章节文件必须能够独立加载。

```json
{
  "schemaVersion": "1.0.0",
  "id": "unit-003",
  "order": 3,
  "kind": "lesson",
  "title": "I am doing",
  "titleZh": "现在进行时",
  "sourcePages": [18, 19],
  "estimatedMinutes": 18,
  "learningObjectives": [
    "理解现在进行时表示正在发生的动作",
    "掌握 am/is/are + verb-ing 结构"
  ],
  "keywords": ["present continuous", "verb-ing", "am", "is", "are"],
  "sections": [
    {
      "id": "unit-003-section-a",
      "type": "concept",
      "title": "基本结构",
      "blocks": [
        {
          "type": "paragraph",
          "text": "现在进行时用于描述现在正在发生的动作。"
        },
        {
          "type": "formula",
          "parts": [
            {"text": "主语", "role": "subject"},
            {"text": "am / is / are", "role": "auxiliary"},
            {"text": "动词 + ing", "role": "verb"}
          ]
        },
        {
          "type": "example",
          "english": "She is eating.",
          "chinese": "她正在吃东西。",
          "highlights": ["is", "eating"]
        },
        {
          "type": "illustration",
          "asset": "assets/illustrations/unit-003-01.webp",
          "alt": "一个人正在吃饭、一个人在雨中行走、三个人正在跑步",
          "caption": ""
        }
      ],
      "sourceRef": {
        "pdfPages": [25],
        "confidence": 0.96
      }
    }
  ],
  "exercises": [],
  "flashcards": [],
  "chapterSummary": [
    "现在进行时的基本结构是 am/is/are + verb-ing。"
  ],
  "quality": {
    "ocrConfidence": 0.95,
    "reviewStatus": "reviewed",
    "issues": []
  }
}
```

### 5.1 section.type

允许值：

- `concept`：概念讲解
- `rule`：规则
- `examples`：例句
- `comparison`：语法对比
- `spelling`：拼写规则
- `note`：注意事项
- `illustration`：教学插图
- `summary`：小结

### 5.2 blocks.type

第一版应用至少支持：

- `heading`
- `paragraph`
- `formula`
- `example`
- `example-list`
- `bullet-list`
- `table`
- `timeline`
- `callout`
- `illustration`
- `audio-text`

表格必须保存为行列数据，不能保存成截图：

```json
{
  "type": "table",
  "columns": ["主语", "be", "动词"],
  "rows": [
    ["I", "am", "working"],
    ["he / she / it", "is", "working"],
    ["we / you / they", "are", "working"]
  ]
}
```

## 6. 手写练习数据

手写输入区域不是普通文本输入框。题目必须使用 `segments` 明确标记文字和横线。

```json
{
  "id": "unit-003-ex-001",
  "type": "fill-blank-handwriting",
  "instruction": "根据提示完成句子。",
  "prompt": {
    "segments": [
      {"type": "text", "text": "Sue "},
      {
        "type": "blank",
        "id": "blank-1",
        "widthEm": 10,
        "lines": 1,
        "handwritingMode": "english"
      },
      {"type": "text", "text": " coffee."}
    ]
  },
  "context": {
    "image": "",
    "hint": "drink"
  },
  "answers": {
    "blank-1": {
      "display": "is drinking",
      "accepted": ["is drinking", "'s drinking", "’s drinking"],
      "tokens": ["is", "drinking"]
    }
  },
  "grading": {
    "mode": "grammar-aware",
    "caseSensitive": false,
    "trimWhitespace": true,
    "collapseWhitespace": true,
    "ignoreTerminalPunctuation": true,
    "normalizeApostrophes": true,
    "maxEditDistance": 1,
    "partialRules": [
      {
        "id": "missing-auxiliary",
        "whenTokensEqual": ["drinking"],
        "result": "partial",
        "feedbackZh": "动词形式正确，但缺少助动词 is。"
      },
      {
        "id": "base-form-only",
        "whenTokensEqual": ["drink"],
        "result": "incorrect",
        "feedbackZh": "这里描述正在发生的动作，需要使用 is drinking。"
      }
    ]
  },
  "feedback": {
    "correctZh": "正确！Sue 是第三人称单数，因此使用 is drinking。",
    "incorrectZh": "再想一想：Sue 应该搭配哪个 be 动词？"
  },
  "sourceRef": {
    "pdfPages": [26],
    "exerciseNumber": "3.1",
    "answerSource": "answer-key",
    "confidence": 0.94
  }
}
```

### 6.1 支持的练习类型

- `fill-blank-handwriting`
- `multi-blank-handwriting`
- `rewrite-sentence-handwriting`
- `short-answer-handwriting`
- `choice`
- `true-false`
- `match`
- `order-words`
- `correction-handwriting`

v1 **保留并接受以上全部九种题型**。五种手写题型完整支持作答与判分；
`choice`/`true-false`/`match`/`order-words` 四种非手写题型的交互作答列入后续迭代，
转换器可如实输出，应用导入后保留并以占位提示展示，不得静默丢弃。

### 6.2 判分约束

- AI 必须尽量从书后答案提取标准答案，不能仅靠猜测。
- `answerSource` 使用 `answer-key`、`explicit-in-page` 或 `ai-inferred`。
- 只要是 `ai-inferred`，必须在 `report.json` 中列入人工复核。
- OCR 识别结果先做大小写、空格和弯直引号标准化，再判分。
- 拼写错误不能因为语法形式接近而直接判正确。
- `maxEditDistance` 只用于提示“可能识别错误”，不能自动把错误答案改成正确。
- 多个横线分别保存答案，不能把整句作为一张不可定位的图片。

## 6.3 复习卡结构与导入语义

章节可选携带 `flashcards`。每张卡结构：

```json
{
  "id": "unit-003-card-001",
  "front": {
    "type": "text",
    "text": "现在进行时的基本结构是什么？"
  },
  "back": {
    "type": "text",
    "text": "am / is / are + verb-ing"
  },
  "tags": ["present-continuous"]
}
```

- `id` 在整本书的 flashcard 范围内唯一并保持版本间稳定。
- 导入 `indexing` 阶段将每张卡幂等写入 `review_cards`：
  `source_type='package'`，
  `source_id='<bookId>:<flashcard.id>'`，
  `front_json=front`，`back_json=back`。
- 新卡初值为 `state='new'`、`ease_factor=2.5`、`interval_days=0`、
  `due_at=created_at`、`lapses=0`。
- 同一来源重复导入时更新 front/back，但保留已有调度状态。

## 7. 插图规范

- 原书插图仅用于理解教学语义，不直接复制到学习包。
- AI 可以生成全新原创教学插图。
- 插图中不写例句、答案和小字号文字，文字由 ArkUI 渲染。
- 同一本书保持统一人物比例、线条、色板和背景风格。
- 每张图片必须有 `alt`。
- 推荐尺寸：1600×1000 或 1200×900。
- 单张建议小于 1.5 MB。
- 封面可以使用用户提供书籍封面缩略图；正文扫描页不得作为课程插图。
- 未生成的插图允许暂时缺省，章节内容不能因此缺失。

## 8. report.json

这是转换质量报告，不直接展示给普通学习者。

```json
{
  "schemaVersion": "1.0.0",
  "status": "completed-with-warnings",
  "stats": {
    "pdfPages": 328,
    "chapters": 115,
    "exercises": 0,
    "illustrations": 0,
    "ocrMeanConfidence": 0.93
  },
  "warnings": [],
  "reviewQueue": [
    {
      "id": "review-001",
      "severity": "medium",
      "type": "ocr-uncertain",
      "file": "chapters/unit-021.json",
      "jsonPath": "$.sections[1].blocks[3]",
      "pdfPages": [61],
      "message": "一个单词的 OCR 置信度低于 0.80。"
    }
  ]
}
```

`status` 允许：

- `completed`
- `completed-with-warnings`
- `failed`

## 9. checksums.json

包含 ZIP 内除自身之外所有文件的 SHA-256：

```json
{
  "algorithm": "sha256",
  "files": {
    "manifest.json": "64位十六进制摘要",
    "book.json": "64位十六进制摘要",
    "chapters/unit-001.json": "64位十六进制摘要"
  }
}
```

应用导入时应验证校验值，失败则拒绝导入并指出文件。

## 10. OCR 与结构化要求

转换 AI 必须：

1. 判断 PDF 是文字版还是扫描版。
2. 扫描版使用中英文 OCR，并保留英文大小写、缩写和标点。
3. 去除重复页眉、页脚、页码和扫描水印。
4. 识别目录、章节标题、小节、正文、语法表格、例句、练习和答案。
5. 建立 PDF 页到章节的映射。
6. 保留原书教学顺序，不自行合并或打乱章节。
7. 目录中的每个教学单元都必须有对应章节文件。
8. 不确定的 OCR 内容保留最佳识别结果，同时写入复核队列。
9. 不得因为页面解析困难而静默丢弃内容。
10. 若章节只有解释页和练习页，应合并为同一章节 JSON。

## 11. 导入前强制验收

生成 AI 必须完成以下检查：

- ZIP 根目录结构正确。
- `manifest.json`、`book.json`、`report.json` 和 `checksums.json` 存在。
- JSON 全部能被标准解析器读取。
- `manifest.book.chapterCount` 与目录章节数一致。
- `book.toc[].file` 全部存在。
- 所有章节 ID 唯一且与目录 ID 一致。
- 所有图片引用存在。
- 每道可判分练习都有答案。
- 所有答案来源可追溯。
- 所有章节至少有一个 `sourceRef`。
- 章节排序连续；若原书编号不连续，必须在报告中解释。
- 校验值正确。
- ZIP 可以完整解压。
- ZIP 内不包含原 PDF。

## 12. 可直接交给 AI 的执行提示词

```text
你是“AI StudyBook Converter”。你的任务是把我提供的 PDF 转换成可导入鸿蒙学习应用的 .studybook.zip。

严格遵守随任务提供的《AI PDF 学习包规范 v1.0》和 JSON Schema。不要输出 PDF 阅读器数据，不要把扫描页当正文图片。你必须把整本书转换成结构化课程。

工作要求：
1. 先判断 PDF 是否有文字层；扫描版执行中英文 OCR。
2. 识别完整目录、所有章节、讲解、规则、例句、表格、插图语义、练习和书后答案。
3. 一个教学单元生成一个 chapters/<id>.json；解释页和对应练习页放在同一个章节中。
4. 题目中的横线必须转换为 prompt.segments 中的 blank，供手写笔直接书写。
5. 从答案页建立标准答案和来源映射。无法确认的答案标记 ai-inferred，并加入 report.json 的 reviewQueue。
6. 保留 PDF 文件页序号 sourceRef；不得静默遗漏难识别内容。
7. 原书插图不得直接复制为正文插图。可以生成原创插图，也可以仅保存插图语义和生成提示。
8. 所有文字使用 UTF-8 JSON；所有路径使用 ZIP 内相对路径。
9. 生成 checksums.json，并执行规范第 11 节的全部验收。
10. 最终交付一个 ZIP 和一段不超过 20 行的转换摘要。不要只交付示例、部分章节或方案。

内容真实性规则：
- 不得凭空增加原书没有的知识点、例句或习题。
- OCR 不确定时写入复核队列，不能假装确定。
- AI 可以生成学习目标、简短章节总结和原创插图提示，但必须与原章内容一致，并与原文提取内容区分。

如果完整转换耗时较长，分批处理并在最后合并，但最终 ZIP 必须包含整本书。
```
