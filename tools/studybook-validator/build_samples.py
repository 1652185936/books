# -*- coding: utf-8 -*-
"""从真实 PDF 元数据构建两个 ai.studybook 学习包测试夹具到 samples/。"""
import os, io, json, zipfile, hashlib, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
REPO = r"D:\worksace\other\books"
SAMPLES = os.path.join(REPO, "samples")
CREATED = "2026-06-19T10:00:00Z"

def sref(pages, src="answer-key", conf=0.95, num=None):
    d = {"pdfPages": pages, "answerSource": src, "confidence": conf}
    if num: d["exerciseNumber"] = num
    return d

def hw_fill(eid, segs, ans, grading, fb, ref):
    return {"id": eid, "type": "fill-blank-handwriting", "instruction": "完成句子。",
            "prompt": {"segments": segs}, "answers": ans, "grading": grading,
            "feedback": fb, "sourceRef": ref}

GRADE = {"mode": "grammar-aware", "caseSensitive": False, "trimWhitespace": True,
         "collapseWhitespace": True, "ignoreTerminalPunctuation": True,
         "normalizeApostrophes": True, "maxEditDistance": 1}

def quality(conf=0.95, status="reviewed", issues=None):
    return {"ocrConfidence": conf, "reviewStatus": status, "issues": issues or []}

# ---------- Murphy: Essential Grammar in Use ----------
murphy_chapters = {}

murphy_chapters["chapters/unit-001.json"] = {
  "schemaVersion": "1.0.0", "id": "unit-001", "order": 1, "kind": "lesson",
  "title": "am / is / are", "titleZh": "be 动词的一般现在时",
  "sourcePages": [16, 17], "estimatedMinutes": 12,
  "keywords": ["be", "present", "am", "is", "are"],
  "sections": [
    {"id": "u1-s1", "type": "rule",
     "blocks": [
        {"type": "heading", "text": "am / is / are"},
        {"type": "paragraph", "text": "be 动词现在时有三种形式：I am，he/she/it is，we/you/they are。"},
        {"type": "bullet-list", "items": ["I am (I'm)", "he / she / it is", "we / you / they are"]}],
     "sourceRef": {"pdfPages": [16], "confidence": 0.96}},
    {"id": "u1-s2", "type": "examples",
     "blocks": [{"type": "example-list", "examples": ["I am cold.", "She is a doctor.", "They are at home."]},
        {"type": "illustration", "asset": "assets/ill-am-is-are.png",
         "alt": "三个人物分别标注 am / is / are 的原创示意图"}],
     "sourceRef": {"pdfPages": [16], "confidence": 0.9}}],
  "exercises": [
    hw_fill("u1-ex1",
      [{"type": "text", "text": "I "}, {"type": "blank", "id": "b1", "widthEm": 6, "lines": 1, "handwritingMode": "english"},
       {"type": "text", "text": " a student."}],
      {"b1": {"display": "am", "accepted": ["am", "'m"], "tokens": ["am"]}},
      GRADE, {"correctZh": "正确，第一人称用 am。", "incorrectZh": "第一人称单数 I 用 am。"},
      sref([17], num="1.1")),
    hw_fill("u1-ex2",
      [{"type": "text", "text": "My friends "}, {"type": "blank", "id": "b1", "widthEm": 7, "lines": 1, "handwritingMode": "english"},
       {"type": "text", "text": " in London."}],
      {"b1": {"display": "are", "accepted": ["are", "'re"], "tokens": ["are"]}},
      GRADE, {"correctZh": "复数主语用 are。", "incorrectZh": "复数主语 friends 用 are。"},
      sref([17], num="1.2"))],
  "flashcards": [
    {"id": "u1-card-1", "front": {"type": "text", "text": "be 动词的三种现在时形式？"},
     "back": {"type": "text", "text": "am / is / are"}, "tags": ["be"]}],
  "quality": quality()}

murphy_chapters["chapters/unit-002.json"] = {
  "schemaVersion": "1.0.0", "id": "unit-002", "order": 2, "kind": "lesson",
  "title": "am / is / are (questions)", "titleZh": "be 动词一般疑问句",
  "sourcePages": [18, 19], "estimatedMinutes": 12, "keywords": ["questions", "be"],
  "sections": [
    {"id": "u2-s1", "type": "rule",
     "blocks": [{"type": "paragraph", "text": "be 动词疑问句把 am/is/are 提到主语前：Are you …? Is she …?"}],
     "sourceRef": {"pdfPages": [18], "confidence": 0.95}}],
  "exercises": [
    hw_fill("u2-ex1",
      [{"type": "blank", "id": "b1", "widthEm": 6, "lines": 1, "handwritingMode": "english"},
       {"type": "text", "text": " you ready?"}],
      {"b1": {"display": "Are", "accepted": ["Are", "are"], "tokens": ["are"]}},
      GRADE, {"correctZh": "对，第二人称疑问用 Are。", "incorrectZh": "you 用 are，疑问句提前。"},
      sref([19], num="2.1")),
    # 非手写题型：保留并占位（R-063），导入不应被拒
    {"id": "u2-ex2", "type": "choice", "instruction": "选择正确的 be 动词形式。",
     "prompt": {"text": "___ she a teacher?", "options": ["Am", "Is", "Are"]},
     "answers": {"correctOption": "Is"}, "grading": {"mode": "exact"},
     "feedback": {"correctZh": "第三人称单数用 Is。"},
     "sourceRef": {"pdfPages": [19], "answerSource": "answer-key", "confidence": 0.93}}],
  "quality": quality()}

murphy_chapters["chapters/unit-003.json"] = {
  "schemaVersion": "1.0.0", "id": "unit-003", "order": 3, "kind": "lesson",
  "title": "Present continuous (I am doing)", "titleZh": "现在进行时",
  "sourcePages": [24, 25], "estimatedMinutes": 15,
  "keywords": ["present continuous", "-ing"],
  "sections": [
    {"id": "u3-s1", "type": "concept",
     "blocks": [{"type": "paragraph", "text": "现在进行时表示此刻正在发生的动作：am/is/are + 动词-ing。"},
        {"type": "formula", "latex": "am/is/are + V-ing", "text": "am/is/are + 动词-ing"}],
     "sourceRef": {"pdfPages": [24], "confidence": 0.97}}],
  "exercises": [
    # 与协议 §6 示例完全一致（弯/直撇号变体 → 触发去重 R-040/R-035）
    {"id": "u3-ex1", "type": "fill-blank-handwriting", "instruction": "根据提示完成句子。",
     "prompt": {"segments": [{"type": "text", "text": "Sue "},
        {"type": "blank", "id": "blank-1", "widthEm": 10, "lines": 1, "handwritingMode": "english"},
        {"type": "text", "text": " coffee."}]},
     "context": {"image": "", "hint": "drink"},
     "answers": {"blank-1": {"display": "is drinking",
        "accepted": ["is drinking", "'s drinking", "’s drinking"], "tokens": ["is", "drinking"]}},
     "grading": {**GRADE, "partialRules": [
        {"id": "missing-auxiliary", "whenTokensEqual": ["drinking"], "result": "partial",
         "feedbackZh": "动词形式正确，但缺少助动词 is。"},
        {"id": "base-form-only", "whenTokensEqual": ["drink"], "result": "incorrect",
         "feedbackZh": "这里描述正在发生的动作，需要使用 is drinking。"}]},
     "feedback": {"correctZh": "正确！Sue 是第三人称单数，因此使用 is drinking。",
        "incorrectZh": "再想一想：Sue 应该搭配哪个 be 动词？"},
     "sourceRef": {"pdfPages": [25], "exerciseNumber": "3.1", "answerSource": "answer-key", "confidence": 0.94}},
    # 多空题
    {"id": "u3-ex2", "type": "multi-blank-handwriting", "instruction": "用括号词的进行时填空。",
     "prompt": {"segments": [{"type": "text", "text": "They "},
        {"type": "blank", "id": "b1", "widthEm": 8, "lines": 1, "handwritingMode": "english"},
        {"type": "text", "text": " football and she "},
        {"type": "blank", "id": "b2", "widthEm": 8, "lines": 1, "handwritingMode": "english"},
        {"type": "text", "text": " TV."}]},
     "answers": {"b1": {"display": "are playing", "accepted": ["are playing"], "tokens": ["are", "playing"]},
        "b2": {"display": "is watching", "accepted": ["is watching"], "tokens": ["is", "watching"]}},
     "grading": GRADE,
     "feedback": {"correctZh": "复数 they 用 are，单数 she 用 is。"},
     # ai-inferred → 需进 reviewQueue（R-008 / IMP-015）
     "sourceRef": {"pdfPages": [25], "exerciseNumber": "3.2", "answerSource": "ai-inferred", "confidence": 0.78}}],
  "flashcards": [
    {"id": "u3-card-1", "front": {"type": "text", "text": "现在进行时的结构？"},
     "back": {"type": "text", "text": "am / is / are + 动词-ing"}, "tags": ["present-continuous"]}],
  "quality": quality(0.84, "needs-review", ["unit-003 多空题答案为 AI 推断，待人工复核"])}

murphy_chapters["chapters/unit-005.json"] = {
  "schemaVersion": "1.0.0", "id": "unit-005", "order": 4, "kind": "lesson",
  "title": "Present simple (I work / she works)", "titleZh": "一般现在时",
  "sourcePages": [32, 33], "estimatedMinutes": 14, "keywords": ["present simple", "third person -s"],
  "sections": [
    {"id": "u5-s1", "type": "rule",
     "blocks": [{"type": "paragraph", "text": "一般现在时表示习惯/事实；第三人称单数动词加 -s/-es。"}],
     "sourceRef": {"pdfPages": [32], "confidence": 0.96}}],
  "exercises": [
    hw_fill("u5-ex1",
      [{"type": "text", "text": "She "}, {"type": "blank", "id": "b1", "widthEm": 7, "lines": 1, "handwritingMode": "english"},
       {"type": "text", "text": " in a bank. (work)"}],
      {"b1": {"display": "works", "accepted": ["works"], "tokens": ["works"]}},
      {**GRADE, "partialRules": [{"id": "wrong-form-base", "whenTokensEqual": ["work"], "result": "partial",
         "feedbackZh": "第三人称单数需加 -s：works。"}]},
      {"correctZh": "正确，第三人称单数加 -s。", "incorrectZh": "she 是第三人称单数，动词加 -s。"},
      sref([33], num="5.1")),
    {"id": "u5-ex2", "type": "short-answer-handwriting", "instruction": "写出 go 的第三人称单数形式。",
     "prompt": {"segments": [{"type": "text", "text": "go → "},
        {"type": "blank", "id": "b1", "widthEm": 8, "lines": 1, "handwritingMode": "english"}]},
     "answers": {"b1": {"display": "goes", "accepted": ["goes"], "tokens": ["goes"]}},
     "grading": GRADE, "feedback": {"correctZh": "go → goes（以 o 结尾加 -es）。"},
     "sourceRef": {"pdfPages": [33], "exerciseNumber": "5.2", "answerSource": "answer-key", "confidence": 0.95}}],
  "quality": quality()}

murphy_chapters["chapters/review-01.json"] = {
  "schemaVersion": "1.0.0", "id": "review-01", "order": 5, "kind": "review",
  "title": "Review: be and tenses", "titleZh": "复习：be 动词与时态",
  "sourcePages": [34], "estimatedMinutes": 8, "keywords": ["review"],
  "sections": [
    {"id": "r1-s1", "type": "summary",
     "blocks": [{"type": "callout", "style": "note", "text": "复习要点：am/is/are 的人称搭配、现在进行时 vs 一般现在时。"}],
     "sourceRef": {"pdfPages": [34], "confidence": 0.95}}],
  "exercises": [],
  "flashcards": [
    {"id": "rv-card-1", "front": {"type": "text", "text": "现在进行时 vs 一般现在时的区别？"},
     "back": {"type": "text", "text": "进行时=此刻正在发生；一般现在时=习惯/事实。"}, "tags": ["review"]}],
  "quality": quality()}

murphy_chapters["chapters/answer-key.json"] = {
  "schemaVersion": "1.0.0", "id": "answer-key", "order": 6, "kind": "answer-key",
  "title": "Key to Exercises", "titleZh": "练习答案",
  "sourcePages": [301], "estimatedMinutes": 1, "keywords": ["answers"],
  "sections": [
    {"id": "ak-s1", "type": "note",
     "blocks": [{"type": "paragraph", "text": "1.1 am  1.2 are  2.1 Are  3.1 is drinking  5.1 works  5.2 goes"}],
     "sourceRef": {"pdfPages": [301], "confidence": 0.99}}],
  "exercises": [],
  "quality": quality(0.99)}

# index 章：sections/exercises 为空 —— 测 R-034 空 sections 导入路径
murphy_chapters["chapters/index.json"] = {
  "schemaVersion": "1.0.0", "id": "index", "order": 7, "kind": "index",
  "title": "Index", "titleZh": "索引", "sourcePages": [316], "estimatedMinutes": 1,
  "sections": [], "exercises": [], "quality": quality(0.99)}

murphy_toc = [
  {"id": "unit-001", "order": 1, "kind": "lesson", "title": "am / is / are", "titleZh": "be 动词一般现在时", "file": "chapters/unit-001.json", "sourcePages": [16, 17], "estimatedMinutes": 12},
  {"id": "unit-002", "order": 2, "kind": "lesson", "title": "am / is / are (questions)", "titleZh": "be 动词疑问句", "file": "chapters/unit-002.json", "sourcePages": [18, 19], "estimatedMinutes": 12},
  {"id": "unit-003", "order": 3, "kind": "lesson", "title": "Present continuous", "titleZh": "现在进行时", "file": "chapters/unit-003.json", "sourcePages": [24, 25], "estimatedMinutes": 15},
  {"id": "unit-005", "order": 4, "kind": "lesson", "title": "Present simple", "titleZh": "一般现在时", "file": "chapters/unit-005.json", "sourcePages": [32, 33], "estimatedMinutes": 14},
  {"id": "review-01", "order": 5, "kind": "review", "title": "Review", "titleZh": "复习", "file": "chapters/review-01.json", "sourcePages": [34], "estimatedMinutes": 8},
  {"id": "answer-key", "order": 6, "kind": "answer-key", "title": "Key to Exercises", "titleZh": "练习答案", "file": "chapters/answer-key.json", "sourcePages": [301], "estimatedMinutes": 1},
  {"id": "index", "order": 7, "kind": "index", "title": "Index", "titleZh": "索引", "file": "chapters/index.json", "sourcePages": [316], "estimatedMinutes": 1}]

murphy_book = {
  "schemaVersion": "1.0.0", "id": "essential-grammar-in-use-3e",
  "title": "剑桥初级英语语法（英语在用）", "subtitle": "Essential Grammar in Use, Third Edition",
  "authors": ["Raymond Murphy"], "description": "剑桥“英语在用”丛书，115 单元语法讲解与练习，适合自学及课堂使用。",
  "languages": ["en", "zh-CN"], "cover": "",
  "source": {"type": "pdf", "originalFileName": "essential-grammar-in-use-3e.pdf", "pdfPageCount": 328, "isScanned": True},
  "defaultChapterId": "unit-001", "toc": murphy_toc}

murphy_manifest = {
  "format": "ai.studybook", "formatVersion": "1.0.0", "contentVersion": "1.0.0",
  "packageId": "essential-grammar-in-use-3e", "createdAt": CREATED,
  "generator": {"name": "books-studybook-builder", "model": "claude-opus-4-8"},
  "entry": "book.json", "contentRoot": "chapters", "assetRoot": "assets",
  "book": {"id": "essential-grammar-in-use-3e", "title": "剑桥初级英语语法（英语在用）",
           "subtitle": "Essential Grammar in Use", "authors": ["Raymond Murphy"],
           "languages": ["en", "zh-CN"], "chapterCount": len(murphy_toc)},
  "checksums": "checksums.json"}

murphy_report = {
  "schemaVersion": "1.0.0", "status": "completed-with-warnings",
  "stats": {"pdfPages": 328, "chapters": len(murphy_toc),
            "exercises": sum(len(c.get("exercises", [])) for c in murphy_chapters.values()),
            "illustrations": 1, "ocrMeanConfidence": 0.93},
  "warnings": ["unit-003 含 AI 推断答案"],
  "reviewQueue": [
    {"id": "review-001", "severity": "medium", "type": "ocr-uncertain",
     "file": "chapters/unit-003.json", "jsonPath": "$.exercises[1].answers",
     "pdfPages": [25], "message": "多空题答案为 AI 推断，置信度 0.78，需人工复核。"}]}

# ---------- New Concept English 1 (study guide) ----------
nce_chapters = {}
nce_chapters["chapters/lesson-001.json"] = {
  "schemaVersion": "1.0.0", "id": "lesson-001", "order": 1, "kind": "lesson",
  "title": "Lesson 1  Excuse me!", "titleZh": "第1课 对不起！",
  "sourcePages": [8, 9], "estimatedMinutes": 10, "keywords": ["greetings", "excuse me"],
  "sections": [
    {"id": "l1-s1", "type": "concept",
     "blocks": [{"type": "paragraph", "text": "本课学习礼貌用语 Excuse me! 与 物主代词 my/your。"},
        {"type": "example-list", "examples": ["Excuse me!", "Yes?", "Is this your handbag?", "Pardon?"]}],
     "sourceRef": {"pdfPages": [8], "confidence": 0.95}}],
  "exercises": [
    hw_fill("l1-ex1",
      [{"type": "text", "text": "Excuse "}, {"type": "blank", "id": "b1", "widthEm": 5, "lines": 1, "handwritingMode": "english"},
       {"type": "text", "text": "!"}],
      {"b1": {"display": "me", "accepted": ["me"], "tokens": ["me"]}},
      GRADE, {"correctZh": "Excuse me! 对不起/打扰一下。"}, sref([9], num="1.1"))],
  "flashcards": [{"id": "l1-card-1", "front": {"type": "text", "text": "“对不起/打扰一下”怎么说？"},
     "back": {"type": "text", "text": "Excuse me!"}, "tags": ["greetings"]}],
  "quality": quality()}

nce_chapters["chapters/lesson-003.json"] = {
  "schemaVersion": "1.0.0", "id": "lesson-003", "order": 2, "kind": "lesson",
  "title": "Lesson 3  Sorry, sir.", "titleZh": "第3课 对不起，先生。",
  "sourcePages": [12, 13], "estimatedMinutes": 10, "keywords": ["this/that", "articles"],
  "sections": [
    {"id": "l3-s1", "type": "rule",
     "blocks": [{"type": "paragraph", "text": "this/that 指示代词与不定冠词 a/an 的用法。"}],
     "sourceRef": {"pdfPages": [12], "confidence": 0.95}}],
  "exercises": [
    hw_fill("l3-ex1",
      [{"type": "text", "text": "This is "}, {"type": "blank", "id": "b1", "widthEm": 4, "lines": 1, "handwritingMode": "english"},
       {"type": "text", "text": " umbrella."}],
      {"b1": {"display": "an", "accepted": ["an"], "tokens": ["an"]}},
      GRADE, {"correctZh": "元音音素前用 an。", "incorrectZh": "umbrella 以元音开头，用 an。"}, sref([13], num="3.1"))],
  "quality": quality()}

nce_chapters["chapters/answer-key.json"] = {
  "schemaVersion": "1.0.0", "id": "answer-key", "order": 3, "kind": "answer-key",
  "title": "Answers", "titleZh": "参考答案", "sourcePages": [240], "estimatedMinutes": 1,
  "sections": [{"id": "ak-s1", "type": "note",
     "blocks": [{"type": "paragraph", "text": "1.1 me  3.1 an"}],
     "sourceRef": {"pdfPages": [240], "confidence": 0.99}}],
  "exercises": [], "quality": quality(0.99)}

nce_toc = [
  {"id": "lesson-001", "order": 1, "kind": "lesson", "title": "Lesson 1 Excuse me!", "titleZh": "第1课", "file": "chapters/lesson-001.json", "sourcePages": [8, 9], "estimatedMinutes": 10},
  {"id": "lesson-003", "order": 2, "kind": "lesson", "title": "Lesson 3 Sorry, sir.", "titleZh": "第3课", "file": "chapters/lesson-003.json", "sourcePages": [12, 13], "estimatedMinutes": 10},
  {"id": "answer-key", "order": 3, "kind": "answer-key", "title": "Answers", "titleZh": "参考答案", "file": "chapters/answer-key.json", "sourcePages": [240], "estimatedMinutes": 1}]

nce_book = {
  "schemaVersion": "1.0.0", "id": "new-concept-english-1-guide",
  "title": "新概念英语1·同步导学", "subtitle": "New Concept English Book 1 — Study Guide",
  "authors": ["新概念英语名师编写组"], "description": "《新概念英语》第一册同步导学，逐课讲解与练习。",
  "languages": ["en", "zh-CN"], "cover": "",
  "source": {"type": "pdf", "originalFileName": "new-concept-english-1-guide.pdf", "pdfPageCount": 251, "isScanned": True},
  "defaultChapterId": "lesson-001", "toc": nce_toc}

nce_manifest = {
  "format": "ai.studybook", "formatVersion": "1.0.0", "contentVersion": "1.0.0",
  "packageId": "new-concept-english-1-guide", "createdAt": CREATED,
  "generator": {"name": "books-studybook-builder", "model": "claude-opus-4-8"},
  "entry": "book.json", "contentRoot": "chapters", "assetRoot": "assets",
  "book": {"id": "new-concept-english-1-guide", "title": "新概念英语1·同步导学",
           "authors": ["新概念英语名师编写组"], "languages": ["en", "zh-CN"], "chapterCount": len(nce_toc)},
  "checksums": "checksums.json"}

nce_report = {
  "schemaVersion": "1.0.0", "status": "completed",
  "stats": {"pdfPages": 251, "chapters": len(nce_toc),
            "exercises": sum(len(c.get("exercises", [])) for c in nce_chapters.values()),
            "illustrations": 0, "ocrMeanConfidence": 0.94},
  "warnings": [], "reviewQueue": []}


def make_illustration(path):
    try:
        from PIL import Image, ImageDraw
        img = Image.new("RGB", (480, 300), (245, 247, 250))
        d = ImageDraw.Draw(img)
        d.rounded_rectangle([40, 60, 200, 240], radius=18, fill=(47, 101, 164))   # 品牌蓝
        d.ellipse([260, 90, 420, 250], fill=(208, 74, 60))                         # 品牌红
        d.rounded_rectangle([150, 30, 330, 70], radius=12, outline=(60, 60, 60), width=3)
        img.save(path, "PNG")
        return True
    except Exception as e:
        print("  (PIL 不可用，跳过插图：%s)" % e)
        return False


def write_tree(root, manifest, book, report, chapters, with_asset=False):
    if os.path.exists(root):
        import shutil; shutil.rmtree(root)
    os.makedirs(os.path.join(root, "chapters"))
    if with_asset:
        os.makedirs(os.path.join(root, "assets"))
    def wj(rel, obj):
        with open(os.path.join(root, rel), "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False, indent=2)
    wj("manifest.json", manifest); wj("book.json", book); wj("report.json", report)
    for rel, obj in chapters.items():
        wj(rel, obj)
    asset_ok = False
    if with_asset:
        asset_ok = make_illustration(os.path.join(root, "assets", "ill-am-is-are.png"))
        if not asset_ok:
            # 去掉引用，保持自洽
            for c in chapters.values():
                for s in c.get("sections", []):
                    s["blocks"] = [b for b in s.get("blocks", []) if b.get("type") != "illustration"]
            wj("chapters/unit-001.json", chapters["chapters/unit-001.json"])
    # checksums：除自身外所有文件
    files = {}
    for dp, _, fns in os.walk(root):
        for fn in fns:
            fp = os.path.join(dp, fn)
            rel = os.path.relpath(fp, root).replace("\\", "/")
            if rel == "checksums.json":
                continue
            files[rel] = hashlib.sha256(open(fp, "rb").read()).hexdigest()
    with open(os.path.join(root, "checksums.json"), "w", encoding="utf-8") as f:
        json.dump({"algorithm": "sha256", "files": files}, f, ensure_ascii=False, indent=2)


def zip_pkg(root, zip_path):
    os.makedirs(os.path.dirname(zip_path), exist_ok=True)
    if os.path.exists(zip_path):
        os.remove(zip_path)
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for dp, _, fns in os.walk(root):
            for fn in fns:
                fp = os.path.join(dp, fn)
                z.write(fp, os.path.relpath(fp, root).replace("\\", "/"))
    return zip_path


tmp = os.path.join(os.environ.get("TEMP", "."), "sb_build")
os.makedirs(tmp, exist_ok=True)

r1 = os.path.join(tmp, "murphy")
write_tree(r1, murphy_manifest, murphy_book, murphy_report, murphy_chapters, with_asset=True)
z1 = zip_pkg(r1, os.path.join(SAMPLES, "essential-grammar-in-use-3e.studybook.zip"))
print("built", z1, os.path.getsize(z1), "bytes")

r2 = os.path.join(tmp, "nce")
write_tree(r2, nce_manifest, nce_book, nce_report, nce_chapters, with_asset=False)
z2 = zip_pkg(r2, os.path.join(SAMPLES, "new-concept-english-1-guide.studybook.zip"))
print("built", z2, os.path.getsize(z2), "bytes")
print("DONE")
