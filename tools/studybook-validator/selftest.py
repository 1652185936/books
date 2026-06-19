# -*- coding: utf-8 -*-
"""studybook 校验器自测：正向（样例包应通过）+ 负向（破坏应被对应 IMP 码拒绝）。

用法: python tools/studybook-validator/selftest.py
退出码 0 = 全部符合预期。
"""
import os, io, sys, json, zipfile, subprocess, tempfile, hashlib
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
VALIDATOR = os.path.join(REPO, "tools", "studybook-validator", "validate.py")
SAMPLES = os.path.join(REPO, "samples")
GOOD = os.path.join(SAMPLES, "essential-grammar-in-use-3e.studybook.zip")
tmp = tempfile.mkdtemp()


def run(zp):
    r = subprocess.run([sys.executable, VALIDATOR, zp], capture_output=True, text=True, encoding="utf-8")
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def read_all(zp):
    z = zipfile.ZipFile(zp); d = {n: z.read(n) for n in z.namelist()}; z.close(); return d


def write_zip(d, name):
    p = os.path.join(tmp, name)
    with zipfile.ZipFile(p, "w", zipfile.ZIP_DEFLATED) as z:
        for n, b in d.items():
            z.writestr(n, b)
    return p


def fix_hash(d, path):
    ck = json.loads(d["checksums.json"])
    ck["files"][path] = hashlib.sha256(d[path]).hexdigest()
    d["checksums.json"] = json.dumps(ck, ensure_ascii=False).encode("utf-8")


print("正向测试：样例包应通过导入校验")
pos_ok = True
for z in ["essential-grammar-in-use-3e.studybook.zip", "new-concept-english-1-guide.studybook.zip"]:
    rc, out = run(os.path.join(SAMPLES, z))
    ok = rc == 0
    pos_ok &= ok
    print(f"  [{'PASS' if ok else 'FAIL'}] {z}  rc={rc}")

print("\n负向测试：每种破坏应被对应 IMP 码拒绝")
base = read_all(GOOD)
cases = []

d = dict(base); d["manifest.json"] = base["manifest.json"].replace(b"essential", b"ESSENTIAL", 1)
cases.append(("篡改文件内容", "IMP-009", write_zip(d, "bad_hash.zip")))

d = dict(base); d["../evil.json"] = b"{}"
cases.append(("路径穿越条目", "IMP-002", write_zip(d, "bad_traversal.zip")))

d = dict(base); c = json.loads(d["chapters/unit-001.json"]); c["exercises"][0]["type"] = "crossword"
d["chapters/unit-001.json"] = json.dumps(c, ensure_ascii=False).encode("utf-8"); fix_hash(d, "chapters/unit-001.json")
cases.append(("未知题型 crossword", "IMP-020", write_zip(d, "bad_type.zip")))

d = dict(base); c = json.loads(d["chapters/unit-001.json"]); c["exercises"][0]["answers"] = {"b1": {"display": "am"}}
d["chapters/unit-001.json"] = json.dumps(c, ensure_ascii=False).encode("utf-8"); fix_hash(d, "chapters/unit-001.json")
cases.append(("手写题缺 accepted", "IMP-012", write_zip(d, "bad_noanswer.zip")))

d = dict(base); m = json.loads(d["manifest.json"]); m["formatVersion"] = "2.0.0"
d["manifest.json"] = json.dumps(m, ensure_ascii=False).encode("utf-8"); fix_hash(d, "manifest.json")
cases.append(("formatVersion 2.0.0", "IMP-006", write_zip(d, "bad_major.zip")))

d = dict(base); c = json.loads(d["chapters/unit-002.json"]); del c["quality"]
d["chapters/unit-002.json"] = json.dumps(c, ensure_ascii=False).encode("utf-8"); fix_hash(d, "chapters/unit-002.json")
cases.append(("chapter 缺 quality", "IMP-008", write_zip(d, "bad_schema.zip")))

d = dict(base); m = json.loads(d["manifest.json"]); m["book"]["chapterCount"] = 99
d["manifest.json"] = json.dumps(m, ensure_ascii=False).encode("utf-8"); fix_hash(d, "manifest.json")
cases.append(("chapterCount 不符", "IMP-011", write_zip(d, "bad_count.zip")))

neg_ok = True
for label, want, zp in cases:
    rc, out = run(zp)
    hit = (want in out) and rc != 0
    neg_ok &= hit
    print(f"  [{'PASS' if hit else 'FAIL'}] {label:18s} 期望 {want} rc={rc} -> {'命中' if want in out else '未命中!'}")

print("\n总判定:", "✅ 正向+负向全部符合预期" if (pos_ok and neg_ok) else "❌ 有用例不符")
sys.exit(0 if (pos_ok and neg_ok) else 1)
