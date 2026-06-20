/**
 * 协议 JSON → 数据库行模型纯映射器（P1-4，LLD §2.4 step11 `indexing` 的「建内容索引」核心逻辑）。
 *
 * 单一真值链：字段级映射、派生、去重/主答案、错误分类一律以《06-协议到数据库映射规范》为准，
 * 表/列/约束以 LLD §3、答案标准化以 §4.3、判分规则映射以 §4.4 / §5 为准。本模块只做
 * 「已通过 §2.4 step1~step10 校验的解析后 JSON」→「待落库行模型」的**纯计算**：
 *   - 不读文件、不触 `@ohos.*`/relationalStore、不持状态、不生成时间戳/随机数（经入参注入），可单测。
 *   - 内部主键（id）经注入的 `IdFactory` 生成（升级期按 external_id 原地更新属 P1-5，本模块只产生新行）。
 *   - 落库与原子提升/提交由 `BookContentRepository` / `ImportIndexer` 承担（SDK 侧）。
 *
 * 覆盖的派生与规则：
 *   - `content_blocks.plain_text` 按 block.type 派生（《06》§3.2），`source_pages` 继承所属小节（§3.1）。
 *   - `sections.confidence ← section.sourceRef.confidence`（§2.1）。
 *   - `accepted_answers`：标准化 + 主答案选取（§4.2 R-030）+ 去重合并（§4.2 R-035），每空恰一 `is_primary=1`。
 *   - `grading_rules`：协议 `grading.partialRules[]` → 规则行（§4.4 R-003）+ 反馈码受控词归一（§5 R-007/R-028）。
 *   - `review_cards`：章节 `flashcards[]` → 复习卡（§3.19.1 / §7），`source_id='<bookId>:<flashcardId>'`。
 *   - `content_review_flags`：`report.json.reviewQueue[]` → 复核标记（§8 R-008）+ IMP-015 警告判定（§2.5 R-037）。
 *   - `assets`：包内 `assets/` 图片 → 资源行（sha256/size 由入参注入；尺寸留空，不解码图片）。
 *   - 阻断校验：未知题型 → IMP-020；可判分题缺答案 → IMP-012；章节 ID/顺序冲突 → IMP-011；
 *     目录引用的章节文件缺失/封面缺失 → IMP-010。
 *
 * 未编译验证（缺 HarmonyOS SDK）：`JsonValue` 递归 Record 联合为 ArkTS 动态对象既定写法（标准 tsc 判 TS2456，
 * 同 `common.ets`/`JsonSchemaValidator.ets` 已记分歧）；逻辑已用等价 Node 端口 + 真实夹具回归验证。
 */
import { JsonValue } from './JsonSchemaValidator';
import { AnswerNormalizer, NormalizeOptions } from './AnswerNormalizer';
import { ImportStateMachine } from './ImportStateMachine';

/** 内部主键生成端口（生产以 `@kit.ArkTS` 的 `util.generateRandomUUID` 实现；单测以确定性序列注入）。 */
export interface IdFactory {
  /**
   * 生成一个新的内部主键（TEXT PK）。
   * @returns 唯一 ID 字符串。
   */
  newId(): string;
}

/** 协议允许的九种题型白名单（LLD §3.8 / 协议 §6.3，R-063 保留全部题型）。 */
export const ALLOWED_EXERCISE_TYPES: string[] = [
  'fill-blank-handwriting', 'multi-blank-handwriting', 'rewrite-sentence-handwriting',
  'short-answer-handwriting', 'choice', 'true-false', 'match', 'order-words', 'correction-handwriting'
];

/** 五种手写题型（v1 完整实现作答与判分，须有可判分答案 → IMP-012 校验对象）。 */
export const HANDWRITING_EXERCISE_TYPES: string[] = [
  'fill-blank-handwriting', 'multi-blank-handwriting', 'rewrite-sentence-handwriting',
  'short-answer-handwriting', 'correction-handwriting'
];

/** 反馈/错误分类受控词表（《06》§5 R-007/R-028）。 */
export const FEEDBACK_CODE_VOCAB: string[] = [
  'missing-auxiliary', 'wrong-tense', 'wrong-form', 'spelling',
  'missing-word', 'extra-word', 'word-order', 'recognition-uncertain', 'other'
];

/** `answer_source` 缺省值：AI 生成学习包默认按「AI 推断」（协议 `sourceRef.answerSource` 可选，CHECK 必为四值之一）。 */
const DEFAULT_ANSWER_SOURCE: string = 'ai-inferred';
/** 空位建议宽度缺省值（em，落在 §3.9 CHECK 3..40 内）。 */
const DEFAULT_BLANK_WIDTH_EM: number = 8;
/** 资源相对路径前缀（包内 `assets/` 目录）。 */
const ASSET_PREFIX: string = 'assets/';
/** 内容块 payload 中可能承载资源相对路径的候选字段名（用于 illustration → asset_id 最佳努力解析）。 */
const ASSET_REF_FIELDS: string[] = ['asset', 'assetPath', 'src', 'path', 'image', 'href', 'relativePath'];

/** `books` 行模型（§3.3，字段名为列名的驼峰映射）。 */
export interface BookRow {
  /** 内部书籍 ID（PK，= 沙箱目录段）。 */
  id: string;
  /** manifest.packageId。 */
  packageId: string;
  /** manifest.contentVersion（去重/升级键）。 */
  contentVersion: string;
  /** manifest.formatVersion（主版本兼容判断）。 */
  formatVersion: string;
  /** 书名（1..200）。 */
  title: string;
  /** 副标题。 */
  subtitle: string;
  /** 作者 JSON 数组串。 */
  authorsJson: string;
  /** 简介。 */
  description: string;
  /** 语言 JSON 数组串。 */
  languagesJson: string;
  /** 封面沙箱相对路径（可空）。 */
  coverPath?: string;
  /** 章节数（插入时取 toc 数量，提交事务内会 SELECT COUNT 重算，§3.3 R-047）。 */
  chapterCount: number;
  /** 原 PDF 页数（可空，仅追溯）。 */
  sourcePageCount?: number;
  /** 是否扫描版（0/1）。 */
  sourceIsScanned: number;
  /** 状态（新导入恒 ready）。 */
  status: string;
  /** 导入时间。 */
  importedAt: number;
  /** 内容更新时间。 */
  updatedAt: number;
}

/** `chapters` 行模型（§3.4）。 */
export interface ChapterRow {
  /** 内部章节 ID。 */
  id: string;
  /** 所属书籍 ID。 */
  bookId: string;
  /** 学习包章节 ID。 */
  externalId: string;
  /** 目录顺序。 */
  orderNo: number;
  /** 章节类型。 */
  kind: string;
  /** 主标题。 */
  title: string;
  /** 中文标题。 */
  titleZh: string;
  /** 预计学习分钟。 */
  estimatedMinutes: number;
  /** 来源页 JSON 数组串。 */
  sourcePagesJson: string;
  /** 章节 JSON 包内相对路径。 */
  contentFile: string;
  /** 章节 JSON 文件 SHA-256（64）。 */
  contentHash: string;
  /** 复核状态。 */
  reviewStatus: string;
  /** 创建时间。 */
  createdAt: number;
  /** 更新时间。 */
  updatedAt: number;
}

/** `sections` 行模型（§3.5）。 */
export interface SectionRow {
  /** 内部小节 ID。 */
  id: string;
  /** 所属章节 ID。 */
  chapterId: string;
  /** 学习包小节 ID。 */
  externalId: string;
  /** 顺序。 */
  orderNo: number;
  /** 小节类型。 */
  type: string;
  /** 标题。 */
  title: string;
  /** 来源页 JSON 数组串。 */
  sourcePagesJson: string;
  /** 内容置信度（← sourceRef.confidence）。 */
  confidence: number;
}

/** `content_blocks` 行模型（§3.6）。 */
export interface ContentBlockRow {
  /** 内容块 ID。 */
  id: string;
  /** 所属小节 ID。 */
  sectionId: string;
  /** 外部 ID（可空）。 */
  externalId?: string;
  /** 顺序。 */
  orderNo: number;
  /** 块类型。 */
  type: string;
  /** 完整结构 JSON 串。 */
  payloadJson: string;
  /** 派生纯文本（§3.2）。 */
  plainText: string;
  /** 关联资源 ID（可空）。 */
  assetId?: string;
  /** 来源页 JSON 数组串（继承小节，§3.1）。 */
  sourcePagesJson: string;
}

/** `exercises` 行模型（§3.8）。 */
export interface ExerciseRow {
  /** 练习 ID。 */
  id: string;
  /** 所属章节 ID。 */
  chapterId: string;
  /** 包内 ID。 */
  externalId: string;
  /** 顺序。 */
  orderNo: number;
  /** 题型。 */
  type: string;
  /** 指令。 */
  instruction: string;
  /** prompt JSON 串。 */
  promptJson: string;
  /** context JSON 串。 */
  contextJson: string;
  /** feedback JSON 串。 */
  feedbackJson: string;
  /** 判分开关 JSON 串（不含 partialRules）。 */
  gradingOptionsJson: string;
  /** 来源 JSON 串。 */
  sourceRefJson: string;
  /** 答案来源。 */
  answerSource: string;
  /** 内容置信度。 */
  confidence: number;
  /** 是否可作答（0/1，导入恒 1）。 */
  enabled: number;
  /** 是否允许空答案提交（0/1）。 */
  allowEmpty: number;
}

/** `exercise_blanks` 行模型（§3.9）。 */
export interface ExerciseBlankRow {
  /** 空位 ID。 */
  id: string;
  /** 所属练习 ID。 */
  exerciseId: string;
  /** prompt 中的 blank id。 */
  blankKey: string;
  /** 空位顺序。 */
  orderNo: number;
  /** 横线建议宽度（em）。 */
  widthEm: number;
  /** 行数。 */
  lines: number;
  /** 识别模式。 */
  handwritingMode: string;
  /** 主答案展示串。 */
  displayAnswer: string;
  /** 语法 token JSON 串。 */
  tokensJson: string;
}

/** `accepted_answers` 行模型（§3.10）。 */
export interface AcceptedAnswerRow {
  /** 答案 ID。 */
  id: string;
  /** 所属空位 ID。 */
  blankId: string;
  /** 标准化答案。 */
  normalizedAnswer: string;
  /** 展示答案。 */
  displayAnswer: string;
  /** 是否主答案（0/1）。 */
  isPrimary: number;
  /** 顺序。 */
  sortOrder: number;
}

/** `grading_rules` 行模型（§3.11）。 */
export interface GradingRuleRow {
  /** 规则 ID。 */
  id: string;
  /** 所属练习 ID。 */
  exerciseId: string;
  /** 限定空位 ID（可空，本版协议规则为题级，恒空）。 */
  blankId?: string;
  /** 优先级（越小越先，§3.11；映射自数组下标）。 */
  priority: number;
  /** 规则类型。 */
  ruleType: string;
  /** 参数 JSON 串。 */
  paramsJson: string;
  /** 结果。 */
  result: string;
  /** 反馈代码（受控词，§5）。 */
  feedbackCode: string;
  /** 中文反馈。 */
  feedbackZh: string;
}

/** `review_cards` 行模型（§3.19，导入仅产生 package 来源卡）。 */
export interface ReviewCardRow {
  /** 卡片 ID。 */
  id: string;
  /** 书籍 ID。 */
  bookId: string;
  /** 章节 ID。 */
  chapterId: string;
  /** 来源（package）。 */
  sourceType: string;
  /** 来源 ID（`<bookId>:<flashcardId>`）。 */
  sourceId: string;
  /** 正面 JSON 串。 */
  frontJson: string;
  /** 背面 JSON 串。 */
  backJson: string;
  /** 状态（新建 new）。 */
  state: string;
  /** 难度系数。 */
  easeFactor: number;
  /** 间隔天数。 */
  intervalDays: number;
  /** 到期时间（= createdAt）。 */
  dueAt: number;
  /** 遗忘次数。 */
  lapses: number;
  /** 创建时间。 */
  createdAt: number;
  /** 更新时间。 */
  updatedAt: number;
}

/** `content_review_flags` 行模型（§3.25）。 */
export interface ContentReviewFlagRow {
  /** 复核项 ID。 */
  id: string;
  /** 书籍 ID。 */
  bookId: string;
  /** 复核项所属章节外部 ID。 */
  chapterExternalId: string;
  /** reviewQueue[].jsonPath。 */
  jsonPath: string;
  /** 严重度。 */
  severity: string;
  /** 类型。 */
  type: string;
  /** 脱敏复核说明。 */
  message: string;
  /** 创建时间。 */
  createdAt: number;
}

/** `assets` 行模型（§3.7）。 */
export interface AssetRow {
  /** 资源 ID。 */
  id: string;
  /** 所属书籍 ID。 */
  bookId: string;
  /** 包内相对路径。 */
  relativePath: string;
  /** 沙箱相对路径（提升后位置）。 */
  localPath: string;
  /** 媒体类型。 */
  mediaType: string;
  /** SHA-256（64）。 */
  sha256: string;
  /** 大小（字节）。 */
  sizeBytes: number;
  /** 宽（像素，本版不解码图片 → 空）。 */
  widthPx?: number;
  /** 高（像素，本版不解码图片 → 空）。 */
  heightPx?: number;
  /** 替代文本。 */
  altText: string;
}

/** 完整书籍索引模型（一次导入事务内落库的全部行 + 警告计数）。 */
export interface BookIndexModel {
  /** 书籍行。 */
  book: BookRow;
  /** 章节行（按 order 升序）。 */
  chapters: ChapterRow[];
  /** 小节行。 */
  sections: SectionRow[];
  /** 内容块行。 */
  blocks: ContentBlockRow[];
  /** 练习行。 */
  exercises: ExerciseRow[];
  /** 空位行。 */
  blanks: ExerciseBlankRow[];
  /** 可接受答案行。 */
  acceptedAnswers: AcceptedAnswerRow[];
  /** 判分规则行。 */
  gradingRules: GradingRuleRow[];
  /** 复习卡行。 */
  reviewCards: ReviewCardRow[];
  /** 复核标记行。 */
  reviewFlags: ContentReviewFlagRow[];
  /** 资源行。 */
  assets: AssetRow[];
  /** 警告计数（IMP-015 非阻断，§2.5 R-037 → import_jobs.warning_count）。 */
  warningCount: number;
}

/** 已解析的章节文件（包内相对路径 + 解析后 JSON 对象）。 */
export interface ChapterFileInput {
  /** 章节 JSON 包内相对路径（如 `chapters/ch01.json`）。 */
  file: string;
  /** 解析后的章节 JSON 对象。 */
  json: Record<string, JsonValue>;
}

/** 映射输入（全部为已校验/已解析的结构化数据 + 注入的 ID/时间/哈希/大小）。 */
export interface MapInput {
  /** 解析后的 manifest.json。 */
  manifest: Record<string, JsonValue>;
  /** 解析后的 book.json。 */
  book: Record<string, JsonValue>;
  /** 解析后的章节文件列表（顺序不限，内部按 order 排序）。 */
  chapters: ChapterFileInput[];
  /** 解析后的 report.json（可选）。 */
  report?: Record<string, JsonValue>;
  /** 暂存全部文件相对路径 → 实际 SHA-256（P1-3 已计算，含章节与资源）。 */
  fileHashes: Record<string, string>;
  /** 暂存全部文件相对路径 → 字节大小。 */
  fileSizes: Record<string, number>;
  /** 预先生成的内部书籍 ID（同时作为沙箱目录段）。 */
  bookId: string;
  /** 导入时间戳（epoch ms，注入）。 */
  now: number;
  /** 内部主键生成器。 */
  ids: IdFactory;
}

/**
 * 协议 → 数据库行模型映射器（静态方法集合，纯函数）。
 */
export class ContentMapper {
  /**
   * 把已校验的学习包解析结果映射为完整 `BookIndexModel`。
   * @param input 映射输入。
   * @returns 待落库的书籍索引模型。
   * @throws AppError 内容不满足落库不变量时抛出（IMP-010/011/012/020，终态拒绝）。
   */
  static map(input: MapInput): BookIndexModel {
    // 资源行（先建，供内容块 asset_id 解析引用）
    const assets: AssetRow[] = ContentMapper.mapAssets(input);
    // 资源相对路径 → 资源 ID（最佳努力链接 illustration 块）
    const assetByPath: Record<string, string> = {};
    for (let i: number = 0; i < assets.length; i++) {
      assetByPath[assets[i].relativePath] = assets[i].id;
    }

    // 书籍行
    const book: BookRow = ContentMapper.mapBook(input);

    // 累积各表行
    const chapters: ChapterRow[] = [];
    const sections: SectionRow[] = [];
    const blocks: ContentBlockRow[] = [];
    const exercises: ExerciseRow[] = [];
    const blanks: ExerciseBlankRow[] = [];
    const acceptedAnswers: AcceptedAnswerRow[] = [];
    const gradingRules: GradingRuleRow[] = [];
    const reviewCards: ReviewCardRow[] = [];

    // 章节文件按相对路径建索引（toc 解析 + IMP-010 引用校验）
    const chapterByFile: Record<string, Record<string, JsonValue>> = {};
    for (let i: number = 0; i < input.chapters.length; i++) {
      chapterByFile[input.chapters[i].file] = input.chapters[i].json;
    }

    // 目录条目（用于校验 file 引用与 id 一致性，§2 / IMP-010 / IMP-011）
    const toc: JsonValue[] = ContentMapper.arr(ContentMapper.obj(input.book, 'toc'));
    // toc 文件 → toc.id（用于复核标记 file → 章节外部 ID 解析，§8）
    const tocFileToId: Record<string, string> = {};

    // 已见外部 ID / 顺序（IMP-011 冲突检测）
    const seenExternalIds: Record<string, boolean> = {};
    const seenOrders: Record<string, boolean> = {};

    // 逐 toc 条目映射章节
    for (let i: number = 0; i < toc.length; i++) {
      // 当前目录条目对象
      const entry: Record<string, JsonValue> | undefined = ContentMapper.asObject(toc[i]);
      if (entry === undefined) {
        continue;
      }
      // 目录声明的章节文件与 ID
      const file: string = ContentMapper.str(entry, 'file', '');
      const tocId: string = ContentMapper.str(entry, 'id', '');
      tocFileToId[file] = tocId;
      // IMP-010：目录引用的章节文件在暂存中缺失
      const chapterJson: Record<string, JsonValue> | undefined = chapterByFile[file];
      if (chapterJson === undefined) {
        throw ImportStateMachine.buildFailure('IMP-010', `missing-chapter-file:${file}`);
      }
      // IMP-011：章节 JSON.id 与目录 id 不一致
      const chapterId: string = ContentMapper.str(chapterJson, 'id', '');
      if (chapterId !== tocId) {
        throw ImportStateMachine.buildFailure('IMP-011', `toc-id-mismatch:${file}`);
      }
      // IMP-011：外部 ID 重复
      if (seenExternalIds[chapterId] === true) {
        throw ImportStateMachine.buildFailure('IMP-011', `duplicate-chapter-id:${chapterId}`);
      }
      seenExternalIds[chapterId] = true;

      // 内部章节 ID
      const internalChapterId: string = input.ids.newId();
      // 章节顺序（取章节 JSON.order，与目录 order 不一致时以内容真值为准）
      const orderNo: number = ContentMapper.num(chapterJson, 'order', i + 1);
      // IMP-011：章节顺序重复
      const orderKey: string = String(orderNo);
      if (seenOrders[orderKey] === true) {
        throw ImportStateMachine.buildFailure('IMP-011', `duplicate-chapter-order:${orderKey}`);
      }
      seenOrders[orderKey] = true;

      // 章节复核状态（quality.reviewStatus，§3.4 / 默认 unreviewed）
      const quality: Record<string, JsonValue> | undefined = ContentMapper.asObject(chapterJson.quality);
      const reviewStatus: string =
        quality !== undefined ? ContentMapper.str(quality, 'reviewStatus', 'unreviewed') : 'unreviewed';

      // 章节行
      chapters.push({
        id: internalChapterId,
        bookId: input.bookId,
        externalId: chapterId,
        orderNo: orderNo,
        kind: ContentMapper.str(chapterJson, 'kind', 'lesson'),
        title: ContentMapper.str(chapterJson, 'title', ''),
        titleZh: ContentMapper.str(chapterJson, 'titleZh', ''),
        estimatedMinutes: ContentMapper.num(chapterJson, 'estimatedMinutes', 1),
        sourcePagesJson: ContentMapper.intArrayJson(chapterJson.sourcePages),
        contentFile: file,
        contentHash: ContentMapper.hashFor(input.fileHashes, file),
        reviewStatus: reviewStatus,
        createdAt: input.now,
        updatedAt: input.now
      });

      // 小节 / 内容块
      ContentMapper.mapSections(chapterJson, internalChapterId, input, assetByPath, sections, blocks);
      // 练习 / 空位 / 答案 / 规则
      ContentMapper.mapExercises(chapterJson, internalChapterId, input, exercises, blanks, acceptedAnswers, gradingRules);
      // 复习卡（章节 flashcards）
      ContentMapper.mapFlashcards(chapterJson, internalChapterId, input, reviewCards);
    }

    // 复核标记 + 警告计数
    const reviewFlags: ContentReviewFlagRow[] = [];
    const warningCount: number =
      ContentMapper.mapReviewFlags(input, tocFileToId, chapters, reviewFlags);

    // 插入态章节数（提交事务内会重算，§3.3 R-047）
    book.chapterCount = chapters.length;

    return {
      book: book,
      chapters: chapters,
      sections: sections,
      blocks: blocks,
      exercises: exercises,
      blanks: blanks,
      acceptedAnswers: acceptedAnswers,
      gradingRules: gradingRules,
      reviewCards: reviewCards,
      reviewFlags: reviewFlags,
      assets: assets,
      warningCount: warningCount
    };
  }

  /**
   * 映射 `books` 行（manifest + book.json，《06》§1/§2）。
   * @param input 映射输入。
   * @returns 书籍行（chapterCount 暂置 0，由 map() 回填）。
   */
  private static mapBook(input: MapInput): BookRow {
    // book.json 的 source 子对象（含 PDF 页数与扫描标识）
    const source: Record<string, JsonValue> | undefined = ContentMapper.asObject(input.book.source);
    // 封面包内相对路径（可空）
    const cover: string = ContentMapper.str(input.book, 'cover', '');
    // 组装书籍行（status 恒 ready；chapterCount 由调用方回填实际章节数）
    const row: BookRow = {
      id: input.bookId,
      packageId: ContentMapper.str(input.manifest, 'packageId', ''),
      contentVersion: ContentMapper.str(input.manifest, 'contentVersion', ''),
      formatVersion: ContentMapper.str(input.manifest, 'formatVersion', ''),
      title: ContentMapper.str(input.book, 'title', ''),
      subtitle: ContentMapper.str(input.book, 'subtitle', ''),
      authorsJson: ContentMapper.stringArrayJson(input.book.authors),
      description: ContentMapper.str(input.book, 'description', ''),
      languagesJson: ContentMapper.stringArrayJson(input.book.languages),
      chapterCount: 0,
      sourceIsScanned: source !== undefined && ContentMapper.boolOf(source.isScanned) ? 1 : 0,
      status: 'ready',
      importedAt: input.now,
      updatedAt: input.now
    };
    // 可空：原 PDF 页数（仅追溯）
    if (source !== undefined) {
      const pageCount: number | undefined = ContentMapper.asNumber(source.pdfPageCount);
      if (pageCount !== undefined && pageCount > 0) {
        row.sourcePageCount = pageCount;
      }
    }
    // 可空：封面沙箱相对路径（IMP-010：声明封面但暂存缺失）
    if (cover.length > 0) {
      if (input.fileHashes[cover] === undefined) {
        throw ImportStateMachine.buildFailure('IMP-010', 'missing-cover-file');
      }
      row.coverPath = ContentMapper.localPath(input.bookId, cover);
    }
    return row;
  }

  /**
   * 映射小节与内容块（§2.1 / §3.1 / §3.2）。
   * @param chapterJson 章节 JSON 对象。
   * @param chapterId 内部章节 ID。
   * @param input 映射输入。
   * @param assetByPath 资源相对路径 → 资源 ID。
   * @param sections 累积小节行（出参）。
   * @param blocks 累积内容块行（出参）。
   */
  private static mapSections(
    chapterJson: Record<string, JsonValue>, chapterId: string, input: MapInput,
    assetByPath: Record<string, string>, sections: SectionRow[], blocks: ContentBlockRow[]): void {
    // 章节小节数组
    const sectionArr: JsonValue[] = ContentMapper.arr(chapterJson.sections);
    for (let i: number = 0; i < sectionArr.length; i++) {
      // 当前小节对象
      const section: Record<string, JsonValue> | undefined = ContentMapper.asObject(sectionArr[i]);
      if (section === undefined) {
        continue;
      }
      // 小节来源引用（pdfPages / confidence 必填，§2.1）
      const sourceRef: Record<string, JsonValue> | undefined = ContentMapper.asObject(section.sourceRef);
      // 块继承的小节来源页 JSON（§3.1）
      const sectionPagesJson: string =
        sourceRef !== undefined ? ContentMapper.intArrayJson(sourceRef.pdfPages) : '[]';
      // 小节置信度（← sourceRef.confidence，§2.1）
      const confidence: number =
        sourceRef !== undefined ? ContentMapper.num(sourceRef, 'confidence', 0) : 0;
      // 内部小节 ID
      const internalSectionId: string = input.ids.newId();
      // 小节行
      sections.push({
        id: internalSectionId,
        chapterId: chapterId,
        externalId: ContentMapper.str(section, 'id', ''),
        orderNo: i + 1,
        type: ContentMapper.str(section, 'type', 'concept'),
        title: ContentMapper.str(section, 'title', ''),
        sourcePagesJson: sectionPagesJson,
        confidence: confidence
      });

      // 小节内容块
      const blockArr: JsonValue[] = ContentMapper.arr(section.blocks);
      for (let j: number = 0; j < blockArr.length; j++) {
        // 当前内容块对象
        const block: Record<string, JsonValue> | undefined = ContentMapper.asObject(blockArr[j]);
        if (block === undefined) {
          continue;
        }
        // 块类型
        const type: string = ContentMapper.str(block, 'type', 'paragraph');
        // 内容块行
        const blockRow: ContentBlockRow = {
          id: input.ids.newId(),
          sectionId: internalSectionId,
          orderNo: j + 1,
          type: type,
          payloadJson: JSON.stringify(block),
          plainText: ContentMapper.derivePlainText(type, block),
          sourcePagesJson: sectionPagesJson
        };
        // 可空：外部 ID
        const externalId: string = ContentMapper.str(block, 'id', '');
        if (externalId.length > 0) {
          blockRow.externalId = externalId;
        }
        // 可空：资源链接（illustration 等，最佳努力解析）
        const assetId: string | undefined = ContentMapper.resolveAssetId(block, assetByPath);
        if (assetId !== undefined) {
          blockRow.assetId = assetId;
        }
        blocks.push(blockRow);
      }
    }
  }

  /**
   * 映射练习、空位、可接受答案与判分规则（§3.8~§3.11 / §4.2~§4.4 / §5）。
   * @param chapterJson 章节 JSON 对象。
   * @param chapterId 内部章节 ID。
   * @param input 映射输入。
   * @param exercises 累积练习行（出参）。
   * @param blanks 累积空位行（出参）。
   * @param acceptedAnswers 累积答案行（出参）。
   * @param gradingRules 累积规则行（出参）。
   * @throws AppError 未知题型 IMP-020、可判分题缺答案 IMP-012。
   */
  private static mapExercises(
    chapterJson: Record<string, JsonValue>, chapterId: string, input: MapInput,
    exercises: ExerciseRow[], blanks: ExerciseBlankRow[],
    acceptedAnswers: AcceptedAnswerRow[], gradingRules: GradingRuleRow[]): void {
    // 章节练习数组
    const exerciseArr: JsonValue[] = ContentMapper.arr(chapterJson.exercises);
    for (let i: number = 0; i < exerciseArr.length; i++) {
      // 当前练习对象
      const exercise: Record<string, JsonValue> | undefined = ContentMapper.asObject(exerciseArr[i]);
      if (exercise === undefined) {
        continue;
      }
      // 题型
      const type: string = ContentMapper.str(exercise, 'type', '');
      // IMP-020：协议九种之外的未知题型
      if (ALLOWED_EXERCISE_TYPES.indexOf(type) < 0) {
        throw ImportStateMachine.buildFailure('IMP-020', `unknown-exercise-type:${type}`);
      }
      // 内部练习 ID
      const internalExerciseId: string = input.ids.newId();
      // 来源引用（answerSource / confidence）
      const sourceRef: Record<string, JsonValue> | undefined = ContentMapper.asObject(exercise.sourceRef);
      // 判分对象（含开关与 partialRules）
      const grading: Record<string, JsonValue> | undefined = ContentMapper.asObject(exercise.grading);
      // 标准化开关（导入与判分共用，§4.2 第 1 条）
      const normalizeOptions: NormalizeOptions = AnswerNormalizer.optionsFrom(grading);

      // 练习行
      exercises.push({
        id: internalExerciseId,
        chapterId: chapterId,
        externalId: ContentMapper.str(exercise, 'id', ''),
        orderNo: i + 1,
        type: type,
        instruction: ContentMapper.str(exercise, 'instruction', ''),
        promptJson: ContentMapper.objectJson(exercise.prompt),
        contextJson: ContentMapper.objectJson(exercise.context),
        feedbackJson: ContentMapper.objectJson(exercise.feedback),
        gradingOptionsJson: ContentMapper.gradingOptionsJson(grading),
        sourceRefJson: ContentMapper.objectJson(exercise.sourceRef),
        answerSource: sourceRef !== undefined
          ? ContentMapper.str(sourceRef, 'answerSource', DEFAULT_ANSWER_SOURCE) : DEFAULT_ANSWER_SOURCE,
        confidence: sourceRef !== undefined ? ContentMapper.num(sourceRef, 'confidence', 0) : 0,
        enabled: 1,
        allowEmpty: ContentMapper.boolOf(exercise.allowEmpty) ? 1 : 0
      });

      // 仅手写题型生成空位/答案/规则（非手写四种导入保留、作答交互后续迭代，R-063）
      const isHandwriting: boolean = HANDWRITING_EXERCISE_TYPES.indexOf(type) >= 0;
      if (isHandwriting) {
        ContentMapper.mapBlanksAndAnswers(
          exercise, internalExerciseId, type, normalizeOptions, input, blanks, acceptedAnswers);
        ContentMapper.mapGradingRules(grading, internalExerciseId, input, gradingRules);
      }
    }
  }

  /**
   * 映射手写题的空位与可接受答案（§3.9/§3.10 + §4.2 主答案/去重 + §4.3 标准化）。
   * @param exercise 练习对象。
   * @param exerciseId 内部练习 ID。
   * @param type 题型。
   * @param options 标准化开关。
   * @param input 映射输入。
   * @param blanks 累积空位行（出参）。
   * @param acceptedAnswers 累积答案行（出参）。
   * @throws AppError 可判分题缺答案 IMP-012。
   */
  private static mapBlanksAndAnswers(
    exercise: Record<string, JsonValue>, exerciseId: string, type: string,
    options: NormalizeOptions, input: MapInput,
    blanks: ExerciseBlankRow[], acceptedAnswers: AcceptedAnswerRow[]): void {
    // prompt 对象与其 segments
    const prompt: Record<string, JsonValue> | undefined = ContentMapper.asObject(exercise.prompt);
    const segments: JsonValue[] = prompt !== undefined ? ContentMapper.arr(prompt.segments) : [];
    // answers 对象（blankKey → {display, accepted, tokens}）
    const answers: Record<string, JsonValue> | undefined = ContentMapper.asObject(exercise.answers);

    // 收集 blank 段（type==='blank'）
    const blankKeys: string[] = [];
    for (let i: number = 0; i < segments.length; i++) {
      // 当前段对象
      const seg: Record<string, JsonValue> | undefined = ContentMapper.asObject(segments[i]);
      if (seg === undefined) {
        continue;
      }
      if (ContentMapper.str(seg, 'type', '') !== 'blank') {
        continue;
      }
      // 空位 key
      const blankKey: string = ContentMapper.str(seg, 'id', '');
      // IMP-012：可判分题的空位缺少对应答案
      const answerEntry: Record<string, JsonValue> | undefined =
        answers !== undefined ? ContentMapper.asObject(answers[blankKey]) : undefined;
      const accepted: JsonValue[] = answerEntry !== undefined ? ContentMapper.arr(answerEntry.accepted) : [];
      if (answerEntry === undefined || accepted.length === 0) {
        throw ImportStateMachine.buildFailure('IMP-012', `blank-answer-missing:${type}`);
      }
      blankKeys.push(blankKey);

      // 主答案展示串
      const display: string = ContentMapper.str(answerEntry, 'display', '');
      // 内部空位 ID
      const blankId: string = input.ids.newId();
      // 空位行
      blanks.push({
        id: blankId,
        exerciseId: exerciseId,
        blankKey: blankKey,
        orderNo: blankKeys.length,
        widthEm: ContentMapper.num(seg, 'widthEm', DEFAULT_BLANK_WIDTH_EM),
        lines: ContentMapper.num(seg, 'lines', 1),
        handwritingMode: ContentMapper.str(seg, 'handwritingMode', 'english'),
        displayAnswer: display,
        tokensJson: ContentMapper.stringArrayJson(answerEntry.tokens)
      });

      // 可接受答案：标准化 + 去重合并 + 主答案选取
      ContentMapper.buildAcceptedAnswers(blankId, display, accepted, options, input, acceptedAnswers);
    }

    // IMP-012：手写题但 prompt 无任何 blank 段（无法采集作答）
    if (blankKeys.length === 0) {
      throw ImportStateMachine.buildFailure('IMP-012', `no-blank-in-handwriting:${type}`);
    }
  }

  /**
   * 为单个空位构建 `accepted_answers` 行：标准化、去重合并（R-035）、主答案选取（R-030）。
   * @param blankId 内部空位 ID。
   * @param display 协议 display 原始串。
   * @param accepted 协议 accepted 字符串数组（已确保非空）。
   * @param options 标准化开关。
   * @param input 映射输入。
   * @param out 累积答案行（出参）。
   */
  private static buildAcceptedAnswers(
    blankId: string, display: string, accepted: JsonValue[],
    options: NormalizeOptions, input: MapInput, out: AcceptedAnswerRow[]): void {
    // display 的标准化串（用于主答案判定）
    const normDisplay: string = AnswerNormalizer.normalize(display, options);
    // 归一后 normalized → 行索引（去重合并：相同 normalized 仅保留首条）
    const indexByNorm: Record<string, number> = {};
    // 本空位的答案行（最终追加进 out）
    const rows: AcceptedAnswerRow[] = [];
    // 顺序计数（按出现顺序递增，R-035）
    let sortOrder: number = 1;

    // 逐条 accepted 标准化 + 去重
    for (let i: number = 0; i < accepted.length; i++) {
      // 当前 accepted 原始串
      const raw: string | undefined = ContentMapper.asString(accepted[i]);
      if (raw === undefined) {
        continue;
      }
      // 标准化串
      const norm: string = AnswerNormalizer.normalize(raw, options);
      // 去重：相同 normalized 撞 UNIQUE(blank_id, normalized_answer)，保留首个 display（预期行为，不算失败）
      if (indexByNorm[norm] !== undefined) {
        continue;
      }
      // 主答案：标准化后等于 normalized(display) 的那条置 is_primary=1（R-030）
      const isPrimary: number = norm === normDisplay ? 1 : 0;
      indexByNorm[norm] = rows.length;
      rows.push({
        id: input.ids.newId(),
        blankId: blankId,
        normalizedAnswer: norm,
        displayAnswer: raw,
        isPrimary: isPrimary,
        sortOrder: sortOrder
      });
      sortOrder = sortOrder + 1;
    }

    // R-030：display 未出现在 accepted 中 → 把 display 自身作为主答案插入
    if (indexByNorm[normDisplay] === undefined) {
      rows.push({
        id: input.ids.newId(),
        blankId: blankId,
        normalizedAnswer: normDisplay,
        displayAnswer: display,
        isPrimary: 1,
        sortOrder: sortOrder
      });
    } else {
      // 确保恰有一条 is_primary=1：把命中 display 的那条置主，其余清零
      for (let i: number = 0; i < rows.length; i++) {
        rows[i].isPrimary = rows[i].normalizedAnswer === normDisplay ? 1 : 0;
      }
    }

    // 追加进总集合
    for (let i: number = 0; i < rows.length; i++) {
      out.push(rows[i]);
    }
  }

  /**
   * 映射 `grading.partialRules[]` → `grading_rules` 行（§4.4 R-003 + §5 受控词归一）。
   * @param grading 判分对象（可能为 undefined）。
   * @param exerciseId 内部练习 ID。
   * @param input 映射输入。
   * @param out 累积规则行（出参）。
   */
  private static mapGradingRules(
    grading: Record<string, JsonValue> | undefined, exerciseId: string,
    input: MapInput, out: GradingRuleRow[]): void {
    // 无 grading 即无规则
    if (grading === undefined) {
      return;
    }
    // partialRules 数组
    const partialRules: JsonValue[] = ContentMapper.arr(grading.partialRules);
    for (let i: number = 0; i < partialRules.length; i++) {
      // 当前规则对象
      const rule: Record<string, JsonValue> | undefined = ContentMapper.asObject(partialRules[i]);
      if (rule === undefined) {
        continue;
      }
      // 协议规则 id（→ feedback_code 来源，§4.4）
      const ruleId: string = ContentMapper.str(rule, 'id', '');
      // 规则类型（缺省 tokens-equal；可由 ruleType 显式指定 missing-token）
      const ruleType: string = ContentMapper.str(rule, 'ruleType', 'tokens-equal');
      // whenTokensEqual → params.tokens
      const tokens: JsonValue[] = ContentMapper.arr(rule.whenTokensEqual);
      // 参数对象（含 tokens；若 id 不在受控词表，保留原 id 于 sourceId，§5）
      const params: Record<string, JsonValue> = { tokens: ContentMapper.toStringArray(tokens) };
      // 反馈码受控词归一（§5）：id 在词表则用之，否则归一为 other 并保留原 id
      let feedbackCode: string = ruleId;
      if (FEEDBACK_CODE_VOCAB.indexOf(ruleId) < 0) {
        feedbackCode = 'other';
        if (ruleId.length > 0) {
          params.sourceId = ruleId;
        }
      }
      // 规则行（priority 取数组下标+1，§4.4「数组下标（从 1）」）
      out.push({
        id: input.ids.newId(),
        exerciseId: exerciseId,
        priority: i + 1,
        ruleType: ruleType,
        paramsJson: JSON.stringify(params),
        result: ContentMapper.str(rule, 'result', 'partial'),
        feedbackCode: feedbackCode,
        feedbackZh: ContentMapper.str(rule, 'feedbackZh', '')
      });
    }
  }

  /**
   * 映射章节 `flashcards[]` → `review_cards` 行（§3.19.1 / §7）。
   * @param chapterJson 章节 JSON 对象。
   * @param chapterId 内部章节 ID。
   * @param input 映射输入。
   * @param out 累积复习卡行（出参）。
   */
  private static mapFlashcards(
    chapterJson: Record<string, JsonValue>, chapterId: string, input: MapInput, out: ReviewCardRow[]): void {
    // 章节 flashcards 数组
    const flashcards: JsonValue[] = ContentMapper.arr(chapterJson.flashcards);
    for (let i: number = 0; i < flashcards.length; i++) {
      // 当前 flashcard 对象
      const card: Record<string, JsonValue> | undefined = ContentMapper.asObject(flashcards[i]);
      if (card === undefined) {
        continue;
      }
      // flashcard 外部 ID（→ source_id 组合键）
      const externalId: string = ContentMapper.str(card, 'id', '');
      // 复习卡行（新卡：state=new、ease=2.5、interval=0、due=createdAt、lapses=0，§3.19.1）
      out.push({
        id: input.ids.newId(),
        bookId: input.bookId,
        chapterId: chapterId,
        sourceType: 'package',
        sourceId: `${input.bookId}:${externalId}`,
        frontJson: ContentMapper.objectJson(card.front),
        backJson: ContentMapper.objectJson(card.back),
        state: 'new',
        easeFactor: 2.5,
        intervalDays: 0,
        dueAt: input.now,
        lapses: 0,
        createdAt: input.now,
        updatedAt: input.now
      });
    }
  }

  /**
   * 映射 `report.json.reviewQueue[]` → `content_review_flags` 行，并计算 IMP-015 警告计数（§8 / §2.5 R-037）。
   * @param input 映射输入。
   * @param tocFileToId 目录文件 → 章节外部 ID 映射。
   * @param chapters 已映射的章节行（检测 needs-review）。
   * @param out 累积复核标记行（出参）。
   * @returns 警告计数（≥1 表示存在待人工复核内容）。
   */
  private static mapReviewFlags(
    input: MapInput, tocFileToId: Record<string, string>,
    chapters: ChapterRow[], out: ContentReviewFlagRow[]): number {
    // report 的 reviewQueue 数组
    const reviewQueue: JsonValue[] =
      input.report !== undefined ? ContentMapper.arr(input.report.reviewQueue) : [];
    for (let i: number = 0; i < reviewQueue.length; i++) {
      // 当前复核项对象
      const item: Record<string, JsonValue> | undefined = ContentMapper.asObject(reviewQueue[i]);
      if (item === undefined) {
        continue;
      }
      // 复核项所属文件 → 章节外部 ID（§8：按 file 解析）
      const file: string = ContentMapper.str(item, 'file', '');
      const chapterExternalId: string = tocFileToId[file] !== undefined ? tocFileToId[file] : '';
      // 复核标记行
      out.push({
        id: input.ids.newId(),
        bookId: input.bookId,
        chapterExternalId: chapterExternalId,
        jsonPath: ContentMapper.str(item, 'jsonPath', ''),
        severity: ContentMapper.str(item, 'severity', 'low'),
        type: ContentMapper.str(item, 'type', ''),
        message: ContentMapper.str(item, 'message', ''),
        createdAt: input.now
      });
    }

    // IMP-015 触发：reviewQueue 非空
    let warning: number = out.length;
    // 或任一章节 needs-review
    let anyNeedsReview: boolean = false;
    for (let i: number = 0; i < chapters.length; i++) {
      if (chapters[i].reviewStatus === 'needs-review') {
        anyNeedsReview = true;
        break;
      }
    }
    // 或 report.status==='completed-with-warnings'
    const reportStatus: string =
      input.report !== undefined ? ContentMapper.str(input.report, 'status', '') : '';
    const reportWarned: boolean = reportStatus === 'completed-with-warnings';
    // 三处统一收敛为「存在待复核 → 至少 1 条警告」
    if (warning === 0 && (anyNeedsReview || reportWarned)) {
      warning = 1;
    }
    return warning;
  }

  /**
   * 映射包内 `assets/` 图片为 `assets` 行（sha256/size 注入，本版不解码图片故尺寸留空）。
   * @param input 映射输入。
   * @returns 资源行数组。
   */
  private static mapAssets(input: MapInput): AssetRow[] {
    // 资源行
    const assets: AssetRow[] = [];
    // 暂存全部文件相对路径
    const files: string[] = Object.keys(input.fileHashes);
    for (let i: number = 0; i < files.length; i++) {
      // 当前文件相对路径
      const path: string = files[i];
      // 仅处理 assets/ 下的图片
      if (path.indexOf(ASSET_PREFIX) !== 0) {
        continue;
      }
      // 媒体类型（按扩展名；非图片跳过）
      const mediaType: string | undefined = ContentMapper.mediaTypeOf(path);
      if (mediaType === undefined) {
        continue;
      }
      // 资源行
      assets.push({
        id: input.ids.newId(),
        bookId: input.bookId,
        relativePath: path,
        localPath: ContentMapper.localPath(input.bookId, path),
        mediaType: mediaType,
        sha256: ContentMapper.hashFor(input.fileHashes, path),
        sizeBytes: input.fileSizes[path] !== undefined ? input.fileSizes[path] : 0,
        altText: ''
      });
    }
    return assets;
  }

  // ----------------------------- 派生与工具 -----------------------------

  /**
   * 按 block.type 派生 `plain_text`（《06》§3.2），统一折叠为单行可搜索文本。
   * @param type 块类型。
   * @param block 块对象。
   * @returns 派生纯文本。
   */
  private static derivePlainText(type: string, block: Record<string, JsonValue>): string {
    // 收集的文本片段
    const parts: string[] = [];
    if (type === 'heading' || type === 'paragraph') {
      parts.push(ContentMapper.str(block, 'text', ''));
    } else if (type === 'formula') {
      // 拼接各 parts[].text（空格分隔）
      ContentMapper.collectField(ContentMapper.arr(block.parts), 'text', parts);
    } else if (type === 'example') {
      parts.push(ContentMapper.str(block, 'english', ''));
      parts.push(ContentMapper.str(block, 'chinese', ''));
    } else if (type === 'example-list') {
      // 各 example 的 english/chinese 顺序拼接
      const examples: JsonValue[] = ContentMapper.arr(block.examples);
      for (let i: number = 0; i < examples.length; i++) {
        const ex: Record<string, JsonValue> | undefined = ContentMapper.asObject(examples[i]);
        if (ex !== undefined) {
          parts.push(ContentMapper.str(ex, 'english', ''));
          parts.push(ContentMapper.str(ex, 'chinese', ''));
        }
      }
    } else if (type === 'bullet-list') {
      // 各列表项文本（项可为字符串或 {text}）
      ContentMapper.collectListItems(ContentMapper.arr(block.items), parts);
    } else if (type === 'table') {
      // 表头 columns + 各 rows 单元格
      ContentMapper.collectStrings(ContentMapper.arr(block.columns), parts);
      const rows: JsonValue[] = ContentMapper.arr(block.rows);
      for (let i: number = 0; i < rows.length; i++) {
        ContentMapper.collectStrings(ContentMapper.arr(rows[i]), parts);
      }
    } else if (type === 'timeline') {
      // 各节点标题/说明
      const nodes: JsonValue[] = ContentMapper.arr(block.events !== undefined ? block.events : block.nodes);
      for (let i: number = 0; i < nodes.length; i++) {
        const node: Record<string, JsonValue> | undefined = ContentMapper.asObject(nodes[i]);
        if (node !== undefined) {
          parts.push(ContentMapper.str(node, 'title', ''));
          parts.push(ContentMapper.str(node, 'description', ''));
        }
      }
    } else if (type === 'callout') {
      parts.push(ContentMapper.str(block, 'title', ''));
      parts.push(ContentMapper.strFirst(block, ['body', 'text'], ''));
    } else if (type === 'illustration') {
      // 仅取替代文本，不含图片二进制
      parts.push(ContentMapper.str(block, 'alt', ''));
    } else if (type === 'audio-text') {
      parts.push(ContentMapper.strFirst(block, ['text', 'transcript'], ''));
    }
    // 折叠多余空白为单行
    return parts.join(' ').replace(/\s+/g, ' ').trim();
  }

  /**
   * illustration 等内容块的资源链接最佳努力解析：在候选字段中找与某资源相对路径匹配的值。
   * @param block 块对象。
   * @param assetByPath 资源相对路径 → 资源 ID。
   * @returns 命中的资源 ID 或 undefined。
   */
  private static resolveAssetId(
    block: Record<string, JsonValue>, assetByPath: Record<string, string>): string | undefined {
    for (let i: number = 0; i < ASSET_REF_FIELDS.length; i++) {
      // 候选字段值
      const value: string | undefined = ContentMapper.asString(block[ASSET_REF_FIELDS[i]]);
      if (value === undefined || value.length === 0) {
        continue;
      }
      // 直接匹配相对路径
      if (assetByPath[value] !== undefined) {
        return assetByPath[value];
      }
      // 匹配 assets/ 前缀补全后的路径
      const prefixed: string = ASSET_PREFIX + value;
      if (assetByPath[prefixed] !== undefined) {
        return assetByPath[prefixed];
      }
    }
    return undefined;
  }

  /**
   * 由协议 `grading` 生成 `grading_options_json`（剔除 partialRules，仅留标量开关 + mode，§4.1）。
   * @param grading 判分对象（可能为 undefined）。
   * @returns JSON 串。
   */
  private static gradingOptionsJson(grading: Record<string, JsonValue> | undefined): string {
    // 无 grading → 空对象
    if (grading === undefined) {
      return '{}';
    }
    // 拷贝标量开关（含 mode），跳过 partialRules（落 grading_rules 表）
    const options: Record<string, JsonValue> = {};
    const keys: string[] = Object.keys(grading);
    for (let i: number = 0; i < keys.length; i++) {
      // 当前键
      const key: string = keys[i];
      if (key === 'partialRules') {
        continue;
      }
      options[key] = grading[key];
    }
    return JSON.stringify(options);
  }

  /**
   * 取文件 SHA-256；缺失视为内部引用不完整（IMP-010）。
   * @param hashes 文件相对路径 → SHA-256。
   * @param file 文件相对路径。
   * @returns SHA-256 串。
   * @throws AppError 哈希缺失时抛 IMP-010。
   */
  private static hashFor(hashes: Record<string, string>, file: string): string {
    // 命中哈希
    const hash: string | undefined = hashes[file];
    if (hash === undefined) {
      throw ImportStateMachine.buildFailure('IMP-010', `missing-file-hash:${file}`);
    }
    return hash;
  }

  /**
   * 计算资源/封面提升后的沙箱相对路径：`books/<bookId>/package/<relativePath>`。
   * @param bookId 内部书籍 ID。
   * @param relativePath 包内相对路径。
   * @returns 沙箱相对路径。
   */
  private static localPath(bookId: string, relativePath: string): string {
    return `books/${bookId}/package/${relativePath}`;
  }

  /**
   * 按扩展名推断图片媒体类型；非受支持图片返回 undefined。
   * @param path 文件相对路径。
   * @returns 媒体类型或 undefined。
   */
  private static mediaTypeOf(path: string): string | undefined {
    // 小写路径用于扩展名匹配
    const lower: string = path.toLowerCase();
    if (ContentMapper.endsWith(lower, '.webp')) {
      return 'image/webp';
    }
    if (ContentMapper.endsWith(lower, '.png')) {
      return 'image/png';
    }
    if (ContentMapper.endsWith(lower, '.jpg') || ContentMapper.endsWith(lower, '.jpeg')) {
      return 'image/jpeg';
    }
    return undefined;
  }

  /**
   * 收集对象数组中某字段的字符串值到目标数组。
   * @param items 对象数组。
   * @param field 字段名。
   * @param out 目标数组（出参）。
   */
  private static collectField(items: JsonValue[], field: string, out: string[]): void {
    for (let i: number = 0; i < items.length; i++) {
      const obj: Record<string, JsonValue> | undefined = ContentMapper.asObject(items[i]);
      if (obj !== undefined) {
        out.push(ContentMapper.str(obj, field, ''));
      }
    }
  }

  /**
   * 收集列表项文本（项可为字符串或 `{text}` 对象）。
   * @param items 列表项数组。
   * @param out 目标数组（出参）。
   */
  private static collectListItems(items: JsonValue[], out: string[]): void {
    for (let i: number = 0; i < items.length; i++) {
      // 字符串项
      const asStr: string | undefined = ContentMapper.asString(items[i]);
      if (asStr !== undefined) {
        out.push(asStr);
        continue;
      }
      // 对象项取 text
      const obj: Record<string, JsonValue> | undefined = ContentMapper.asObject(items[i]);
      if (obj !== undefined) {
        out.push(ContentMapper.str(obj, 'text', ''));
      }
    }
  }

  /**
   * 收集字符串数组中的全部字符串值。
   * @param items 数组。
   * @param out 目标数组（出参）。
   */
  private static collectStrings(items: JsonValue[], out: string[]): void {
    for (let i: number = 0; i < items.length; i++) {
      const asStr: string | undefined = ContentMapper.asString(items[i]);
      if (asStr !== undefined) {
        out.push(asStr);
      }
    }
  }

  // ----------------------------- JSON 访问器 -----------------------------

  /**
   * 把 JSON 值断言为对象（非对象/数组/null 返回 undefined）。
   * @param value JSON 值。
   * @returns 对象或 undefined。
   */
  private static asObject(value: JsonValue | undefined): Record<string, JsonValue> | undefined {
    if (value === null || value === undefined || Array.isArray(value)) {
      return undefined;
    }
    return typeof value === 'object' ? value as Record<string, JsonValue> : undefined;
  }

  /**
   * 把 JSON 值断言为数组（非数组返回空数组）。
   * @param value JSON 值。
   * @returns 数组。
   */
  private static asArrayOrEmpty(value: JsonValue | undefined): JsonValue[] {
    return Array.isArray(value) ? value : [];
  }

  /**
   * `asArrayOrEmpty` 的短别名（语义同：取数组或空）。
   * @param value JSON 值。
   * @returns 数组。
   */
  private static arr(value: JsonValue | undefined): JsonValue[] {
    return ContentMapper.asArrayOrEmpty(value);
  }

  /**
   * 取对象某键的子对象。
   * @param obj 父对象。
   * @param key 键。
   * @returns 子对象或 undefined。
   */
  private static obj(obj: Record<string, JsonValue>, key: string): JsonValue | undefined {
    return obj[key];
  }

  /**
   * 把 JSON 值断言为字符串（非字符串返回 undefined）。
   * @param value JSON 值。
   * @returns 字符串或 undefined。
   */
  private static asString(value: JsonValue | undefined): string | undefined {
    return typeof value === 'string' ? value : undefined;
  }

  /**
   * 把 JSON 值断言为数字（非数字返回 undefined）。
   * @param value JSON 值。
   * @returns 数字或 undefined。
   */
  private static asNumber(value: JsonValue | undefined): number | undefined {
    return typeof value === 'number' ? value : undefined;
  }

  /**
   * 读取对象字段为字符串，缺失/非串时回退默认值。
   * @param obj 对象。
   * @param key 键。
   * @param fallback 默认值。
   * @returns 字符串。
   */
  private static str(obj: Record<string, JsonValue>, key: string, fallback: string): string {
    const value: string | undefined = ContentMapper.asString(obj[key]);
    return value !== undefined ? value : fallback;
  }

  /**
   * 按候选键顺序读取首个存在的字符串字段，全缺失时回退默认值。
   * @param obj 对象。
   * @param keys 候选键。
   * @param fallback 默认值。
   * @returns 字符串。
   */
  private static strFirst(obj: Record<string, JsonValue>, keys: string[], fallback: string): string {
    for (let i: number = 0; i < keys.length; i++) {
      const value: string | undefined = ContentMapper.asString(obj[keys[i]]);
      if (value !== undefined) {
        return value;
      }
    }
    return fallback;
  }

  /**
   * 读取对象字段为数字，缺失/非数字时回退默认值。
   * @param obj 对象。
   * @param key 键。
   * @param fallback 默认值。
   * @returns 数字。
   */
  private static num(obj: Record<string, JsonValue>, key: string, fallback: number): number {
    const value: number | undefined = ContentMapper.asNumber(obj[key]);
    return value !== undefined ? value : fallback;
  }

  /**
   * 读取 JSON 值为布尔（非布尔视为 false）。
   * @param value JSON 值。
   * @returns 布尔。
   */
  private static boolOf(value: JsonValue | undefined): boolean {
    return value === true;
  }

  /**
   * 字符串后缀判断。
   * @param s 主串。
   * @param suffix 后缀。
   * @returns 命中返回 true。
   */
  private static endsWith(s: string, suffix: string): boolean {
    if (suffix.length > s.length) {
      return false;
    }
    return s.substring(s.length - suffix.length) === suffix;
  }

  /**
   * 把 JSON 值序列化为对象 JSON 串；非对象（缺失/数组/原始值）落 `'{}'`。
   * @param value JSON 值。
   * @returns JSON 串。
   */
  private static objectJson(value: JsonValue | undefined): string {
    const obj: Record<string, JsonValue> | undefined = ContentMapper.asObject(value);
    return obj !== undefined ? JSON.stringify(obj) : '{}';
  }

  /**
   * 把 JSON 值序列化为整数数组 JSON 串（仅保留整数项）；非数组落 `'[]'`。
   * @param value JSON 值。
   * @returns JSON 串。
   */
  private static intArrayJson(value: JsonValue | undefined): string {
    // 结果整数数组
    const ints: number[] = [];
    const items: JsonValue[] = ContentMapper.arr(value);
    for (let i: number = 0; i < items.length; i++) {
      const n: number | undefined = ContentMapper.asNumber(items[i]);
      if (n !== undefined) {
        ints.push(Math.trunc(n));
      }
    }
    return JSON.stringify(ints);
  }

  /**
   * 把 JSON 值序列化为字符串数组 JSON 串（仅保留字符串项）；非数组落 `'[]'`。
   * @param value JSON 值。
   * @returns JSON 串。
   */
  private static stringArrayJson(value: JsonValue | undefined): string {
    return JSON.stringify(ContentMapper.toStringArray(ContentMapper.arr(value)));
  }

  /**
   * 把 JSON 值数组收敛为字符串数组（仅保留字符串项）。
   * @param items JSON 值数组。
   * @returns 字符串数组。
   */
  private static toStringArray(items: JsonValue[]): string[] {
    // 结果字符串数组
    const out: string[] = [];
    for (let i: number = 0; i < items.length; i++) {
      const s: string | undefined = ContentMapper.asString(items[i]);
      if (s !== undefined) {
        out.push(s);
      }
    }
    return out;
  }
}
