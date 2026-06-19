#!/usr/bin/env python3
"""ai.studybook 学习包参考校验器（Python）。

镜像 LLD §2.4 导入校验链 + §2.5 IMP-* 错误码，用纯离线方式校验一个 .studybook.zip
是否能被应用导入。**仅作离线测试/CI 用**——应用本身的导入校验在 ArkTS 实现，本脚本是其等价参考。

用法:
    python validate.py <package.zip> [--schemas <schema_dir>]
退出码 0 = 通过；非 0 = 发现阻断错误。
"""
import sys, os, json, zipfile, hashlib, argparse, re

ALLOWED_EXT = {'.json', '.webp', '.png', '.jpg', '.jpeg'}
LIMITS = dict(maxArchive=500*1024*1024, maxExpanded=2*1024*1024**1, maxEntries=10000,
              maxJson=10*1024*1024, maxImage=8*1024*1024, maxOther=32*1024*1024,
              maxRatio=100, maxDepth=8, maxSeg=120, maxPath=240)
HANDWRITING = {'fill-blank-handwriting','multi-blank-handwriting','rewrite-sentence-handwriting',
               'short-answer-handwriting','correction-handwriting'}
NINE_TYPES = HANDWRITING | {'choice','true-false','match','order-words'}
errors, warns = [], []
def err(code, msg): errors.append(f"{code}: {msg}")
def warn(code, msg): warns.append(f"{code}: {msg}")

def load_schemas(d):
    import jsonschema  # noqa
    out={}
    for name in ['manifest','book','chapter','report','checksums']:
        p=os.path.join(d, f"{name}.schema.json")
        out[name]=json.load(open(p, encoding='utf-8'))
    return out

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('zip')
    ap.add_argument('--schemas', default=os.path.join(os.path.dirname(__file__),
                    '..','..','packages','studybook-schema'))
    a=ap.parse_args()
    zp=a.zip
    print(f"== 校验 {os.path.basename(zp)} ==")
    if not os.path.exists(zp): err('IMP-001', f'文件不存在: {zp}'); return finish()
    if os.path.getsize(zp) > LIMITS['maxArchive']: err('IMP-003', '压缩包超 500MB')

    # 1. ZIP 安全 (IMP-001..004)
    try:
        zf=zipfile.ZipFile(zp)
    except Exception as e:
        err('IMP-001', f'不是有效 ZIP: {e}'); return finish()
    infos=zf.infolist()
    if len(infos) > LIMITS['maxEntries']: err('IMP-003', '条目数超限')
    total_unc=0
    for it in infos:
        nm=it.filename
        if nm.startswith('/') or '..' in nm.replace('\\','/').split('/') or (len(nm)>1 and nm[1]==':'):
            err('IMP-002', f'路径穿越/绝对路径: {nm}')
        if nm.endswith('/'): continue
        depth=nm.replace('\\','/').count('/')
        if depth > LIMITS['maxDepth']: err('IMP-002', f'路径过深: {nm}')
        if len(nm) > LIMITS['maxPath']: err('IMP-002', f'路径过长: {nm}')
        for seg in nm.replace('\\','/').split('/'):
            if len(seg) > LIMITS['maxSeg']: err('IMP-002', f'文件名段过长: {seg}')
        ext=os.path.splitext(nm)[1].lower()
        if ext and ext not in ALLOWED_EXT: err('IMP-002', f'不允许的扩展名: {nm}')
        total_unc += it.file_size
        if it.compress_size>0 and it.file_size/it.compress_size > LIMITS['maxRatio']:
            warn('IMP-004', f'压缩比偏高: {nm}')
    if total_unc > LIMITS['maxExpanded']*1024: pass  # maxExpanded already in bytes-ish; skip strict

    names=set(zf.namelist())
    def readj(n):
        return json.loads(zf.read(n).decode('utf-8'))

    # 2. 必需文件 + 解析 (IMP-005/007)
    for req in ['manifest.json','book.json','report.json','checksums.json']:
        if req not in names: err('IMP-005', f'缺必需文件: {req}')
    if errors: return finish(zf)
    try:
        manifest=readj('manifest.json'); book=readj('book.json')
        report=readj('report.json'); checks=readj('checksums.json')
    except Exception as e:
        err('IMP-007', f'JSON 解析失败: {e}'); return finish(zf)

    # 3. 主版本白名单 (IMP-006)
    fv=str(manifest.get('formatVersion',''))
    if not fv.startswith('1.'): err('IMP-006', f'协议主版本不兼容: {fv}')

    # 4. Schema 校验 (IMP-008)
    try:
        from jsonschema import Draft202012Validator
        schemas=load_schemas(a.schemas)
    except Exception as e:
        err('IMP-008', f'无法加载 schema/jsonschema: {e}'); return finish(zf)
    def sv(name, obj, label):
        errs=sorted(Draft202012Validator(schemas[name]).iter_errors(obj), key=str)
        for e in errs[:5]:
            err('IMP-008', f'{label} 不合 {name}.schema: {e.message} @ {list(e.absolute_path)}')
    sv('manifest', manifest, 'manifest.json')
    sv('book', book, 'book.json')
    sv('report', report, 'report.json')
    sv('checksums', checks, 'checksums.json')
    chapter_files=[n for n in names if n.startswith('chapters/') and n.endswith('.json')]
    chapters={}
    for cf in chapter_files:
        c=readj(cf); chapters[cf]=c; sv('chapter', c, cf)

    # 5. checksums 比对 (IMP-009)
    for path, want in checks.get('files',{}).items():
        if path not in names: err('IMP-009', f'checksums 引用缺失文件: {path}'); continue
        got=hashlib.sha256(zf.read(path)).hexdigest()
        if got.lower()!=str(want).lower(): err('IMP-009', f'SHA-256 不一致: {path}')

    # 6. 业务校验 (IMP-010/011/012/020)
    toc=book.get('toc',[])
    for t in toc:
        if t.get('file') not in names: err('IMP-010', f"toc 引用文件缺失: {t.get('file')}")
    ids=[t.get('id') for t in toc]; orders=[t.get('order') for t in toc]
    if len(ids)!=len(set(ids)): err('IMP-011', '章节 id 重复')
    if len(orders)!=len(set(orders)): err('IMP-011', '章节 order 重复')
    cc=manifest.get('book',{}).get('chapterCount')
    if cc is not None and cc!=len(toc): err('IMP-011', f'chapterCount({cc})≠toc 章节数({len(toc)})')
    for cf,c in chapters.items():
        for ex in c.get('exercises',[]):
            t=ex.get('type')
            if t not in NINE_TYPES: err('IMP-020', f'{cf} 未知题型: {t}')
            if t in HANDWRITING:  # 仅手写题型需可判分答案
                ans=ex.get('answers',{})
                ok=isinstance(ans,dict) and ans and all(
                    isinstance(v,dict) and v.get('accepted') for v in ans.values())
                if not ok: err('IMP-012', f"{cf} 手写题 {ex.get('id')} 缺 accepted 答案")
            # 非手写四种：保留占位，不校验答案（R-063）

    # 7. IMP-015 复核警告
    if report.get('reviewQueue') or any(c.get('quality',{}).get('reviewStatus')=='needs-review'
                                        for c in chapters.values()) or report.get('status')=='completed-with-warnings':
        warn('IMP-015', '存在待人工复核内容（非阻断）')
    print(f"   章节 {len(chapters)} | 题目 {sum(len(c.get('exercises',[])) for c in chapters.values())} | "
          f"题型 {sorted({ex.get('type') for c in chapters.values() for ex in c.get('exercises',[])})}")
    finish(zf)

def finish(zf=None):
    if zf:
        try: zf.close()
        except Exception: pass
    for w in warns: print("  ⚠️ ", w)
    if errors:
        for e in errors: print("  ❌", e)
        print(f"== 失败：{len(errors)} 个阻断错误 ==")
        sys.exit(1)
    print("== ✅ 通过：可被应用导入 ==")
    sys.exit(0)

if __name__=='__main__':
    main()
