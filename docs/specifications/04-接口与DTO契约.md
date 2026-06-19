# 墨学书架接口与 DTO 契约

| 项目 | 内容 |
|---|---|
| 文档编号 | MX-API-001 |
| 版本 | 1.2.0 |
| 状态 | 评审修订版 |
| 适用范围 | HLD §8、LLD §7 |
| 编写日期 | 2026-06-19 |

本文是跨模块 ArkTS 接口与 DTO 的唯一真值。HLD 和 LLD 中的同名类型必须与本文一致，
不得自行增加必填字段或改变枚举语义。

## 1. 通用类型

```ts
type Id = string;
type EpochMs = number;
type JsonObject = Record<string, string | number | boolean | null | JsonObject | JsonObject[]>;

type PageRequest = {
  cursor?: string;
  limit: number; // 1..100
};

type PageResult<T> = {
  items: T[];
  nextCursor?: string;
  total?: number;
};

type AppError = {
  code: string;
  messageKey: string;
  retryable: boolean;
  detail?: string; // 已脱敏，最多 1000 字符
};
```

所有 Promise 失败必须抛出或返回可转换为 `AppError` 的领域错误，不得抛裸字符串。

## 2. 导入与校验 DTO

```ts
type ValidationOptions = {
  maxArchiveBytes: number;
  maxExpandedBytes: number;
  maxEntries: number;
  maxCompressionRatio: number;
  supportedFormatMajors: number[];
};

type ValidationStage =
  | 'validating-zip'
  | 'validating-manifest'
  | 'extracting-to-staging'
  | 'validating-hash'
  | 'validating-schema'
  | 'validating-business';

type ValidationEvent = {
  jobId: Id;
  stage: ValidationStage;
  progress: number; // 0..1
  checkedFiles: number;
  totalFiles?: number;
  warningCount: number;
  blockingError?: AppError;
};

type ImportProgressEvent = ValidationEvent | {
  jobId: Id;
  stage: 'awaiting-confirmation' | 'indexing' | 'promoting-to-final' | 'committing' | 'completed';
  progress: number;
  warningCount: number;
  blockingError?: AppError;
};

type ImportResult = {
  jobId: Id;
  bookId: Id;
  packageId: string;
  contentVersion: string;
  mode: 'new' | 'upgrade';
  chapterCount: number;
  warningCount: number;
  completedAt: EpochMs;
};

interface PackageValidator {
  validate(sourceUri: string, options: ValidationOptions): AsyncIterable<ValidationEvent>;
}

interface ImportService {
  create(sourceUri: string): Promise<Id>;
  runValidation(jobId: Id): AsyncIterable<ImportProgressEvent>;
  commit(jobId: Id, mode: 'new' | 'upgrade'): Promise<ImportResult>;
  cancel(jobId: Id): Promise<void>;
}
```

## 3. 书籍与内容 DTO

```ts
type BookStatus = 'ready' | 'updating' | 'broken' | 'deleted';
type ChapterKind = 'lesson' | 'review' | 'appendix' | 'answer-key' | 'index';

type BookSummary = {
  id: Id;
  packageId: string;
  contentVersion: string;
  title: string;
  subtitle: string;
  authors: string[];
  coverUri?: string;
  chapterCount: number;
  completionPercent: number; // 0..100，1 位小数
  status: BookStatus;
  lastOpenedAt?: EpochMs;
  continueTarget?: {
    chapterId: Id;
    sectionId?: Id;
    blockId?: Id;
  };
};

type BookDetail = BookSummary & {
  description: string;
  languages: string[];
  importedAt: EpochMs;
  updatedAt: EpochMs;
};

type ChapterSummary = {
  id: Id;
  externalId: string;
  bookId: Id;
  orderNo: number;
  kind: ChapterKind;
  title: string;
  titleZh: string;
  estimatedMinutes: number;
  completionPercent: number;
  progressStatus: 'not-started' | 'learning' | 'completed' | 'review-due';
  reviewStatus: 'unreviewed' | 'needs-review' | 'reviewed';
};

type ContentBlock = {
  id: Id;
  sectionId: Id;
  orderNo: number;
  type:
    | 'heading'
    | 'paragraph'
    | 'formula'
    | 'example'
    | 'example-list'
    | 'bullet-list'
    | 'table'
    | 'timeline'
    | 'callout'
    | 'illustration'
    | 'audio-text';
  payload: JsonObject;
  plainText: string;
  assetUri?: string;
  sourcePages: number[];
};

type SectionContent = {
  id: Id;
  externalId: string;
  type: string;
  title: string;
  blocks: ContentBlock[];
};

type ChapterContent = {
  chapter: ChapterSummary;
  sections: SectionContent[];
  exerciseIds: Id[];
};

type BookListQuery = {
  sort: 'last-opened' | 'title' | 'imported-at';
  keyword?: string;
  includeBroken?: boolean;
};

type SearchResult = {
  chapterId: Id;
  externalId: string;
  title: string;
  titleZh: string;
  orderNo: number;
  matchedField: 'title' | 'titleZh' | 'keyword';
  matchedText: string;
};

interface BooksRepository {
  list(query: BookListQuery): Promise<BookSummary[]>;
  get(bookId: Id): Promise<BookDetail>;
  listChapters(bookId: Id): Promise<ChapterSummary[]>;
  searchChapters(bookId: Id, keyword: string): Promise<SearchResult[]>;
  markBroken(bookId: Id, reasonCode: string): Promise<void>;
}

interface ContentRepository {
  getChapter(chapterId: Id): Promise<ChapterContent>;
  getAssetUri(assetId: Id): Promise<string | undefined>;
  getCoverUri(bookId: Id): Promise<string | undefined>;
}
```

`ImportedBook` 是导入模块内部结构，不得跨模块暴露；其字段由
《协议到数据库映射规范》定义。数据库事务句柄也不得出现在 Presentation 接口中。

## 4. 阅读进度 DTO

```ts
type ReadingProgress = {
  bookId: Id;
  chapterId: Id;
  status: 'not-started' | 'learning' | 'completed' | 'review-due';
  completionPercent: number;
  lastSectionId?: Id;
  lastBlockId?: Id;
  scrollAnchor: JsonObject;
  firstOpenedAt?: EpochMs;
  lastOpenedAt?: EpochMs;
  completedAt?: EpochMs;
};

type SaveReadingAnchorInput = {
  bookId: Id;
  chapterId: Id;
  sectionId?: Id;
  blockId?: Id;
  scrollAnchor: JsonObject;
  activeDurationMs: number;
  savedAt: EpochMs;
};

type SectionReadEvidence = {
  bookId: Id;
  chapterId: Id;
  sectionId: Id;
  maxVisibleRatio: number; // 0..1
  activeDurationMs: number;
  leftForNextSectionOrExercise: boolean;
  observedAt: EpochMs;
};

interface ProgressRepository {
  getChapterProgress(bookId: Id, chapterId: Id): Promise<ReadingProgress>;
  saveAnchor(input: SaveReadingAnchorInput): Promise<void>;
  saveSectionEvidence(input: SectionReadEvidence): Promise<void>;
}

interface ProgressService {
  recomputeChapter(bookId: Id, chapterId: Id): Promise<ReadingProgress>;
  recomputeBook(bookId: Id): Promise<number>;
}
```

## 5. 手写与识别 DTO

```ts
type HandwritingMode = 'english' | 'number' | 'mixed';

type StrokePoint = {
  x: number;
  y: number;
  t: number;
  pressure: number; // 0..1
  tiltX: number;
  tiltY: number;
};

type Stroke = {
  id: Id;
  points: StrokePoint[];
};

type StrokeDocument = {
  format: 'ai.studybook.stroke';
  version: 1;
  canvas: { widthVp: number; heightVp: number };
  strokes: Stroke[];
};

type HandwritingTarget = {
  type: 'exercise-blank' | 'note' | 'review-answer';
  ownerId: Id;
  blankKey?: string;
  mode: HandwritingMode;
  canvasWidthVp: number;
  canvasHeightVp: number;
};

type StrokeSession = {
  sessionId: Id;
  target: HandwritingTarget;
  document: StrokeDocument;
  dirty: boolean;
  updatedAt: EpochMs;
};

type RecognitionErrorCode =
  | 'timeout'
  | 'empty-text'
  | 'service-unavailable'
  | 'unsupported-mode'
  | 'internal-error';

type RecognitionResult =
  | {
      ok: true;
      requestId: Id;
      text: string;
      modelVersion: string;
      durationMs: number;
    }
  | {
      ok: false;
      requestId: Id;
      errorCode: RecognitionErrorCode;
      retryable: boolean;
      durationMs: number;
    };

type RecognitionHandle = {
  requestId: Id;
  result: Promise<RecognitionResult>;
  cancel(): void;
};

interface HandwritingRecognizer {
  recognize(input: StrokeDocument, mode: HandwritingMode): RecognitionHandle;
}

interface HandwritingService {
  begin(target: HandwritingTarget): StrokeSession;
  persistDraft(session: StrokeSession): Promise<void>;
  recognize(session: StrokeSession): RecognitionHandle;
}
```

## 6. 练习与判分 DTO

练习题型（v1 保留全部九种；非手写四种的作答交互列入后续迭代）：

```ts
type ExerciseType =
  | 'fill-blank-handwriting'
  | 'multi-blank-handwriting'
  | 'rewrite-sentence-handwriting'
  | 'short-answer-handwriting'
  | 'choice'
  | 'true-false'
  | 'match'
  | 'order-words'
  | 'correction-handwriting';

type ExerciseBlank = {
  id: Id;
  blankKey: string;
  orderNo: number;
  widthEm: number;
  lines: number;
  handwritingMode: HandwritingMode;
  displayAnswer: string;
  acceptedAnswers: string[];
};

type ExerciseDetail = {
  id: Id;
  externalId: string;
  bookId: Id;
  chapterId: Id;
  orderNo: number;
  type: ExerciseType;
  instruction: string;
  prompt: JsonObject;
  context: JsonObject;
  blanks: ExerciseBlank[];
  gradingOptions: {
    caseSensitive: boolean;
    trimWhitespace: boolean;
    collapseWhitespace: boolean;
    ignoreTerminalPunctuation: boolean;
    normalizeApostrophes: boolean;
    maxEditDistance: number;
  };
};

type ConfirmedAnswer = {
  blankKey: string;
  recognizedText: string;
  strokeRecordId: Id;
};

type BlankGradeResult = {
  blankKey: string;
  recognizedText: string;
  normalizedText: string;
  result: 'correct' | 'partial' | 'incorrect';
  score: 0 | 0.5 | 1;
  feedbackCode: string;
  feedbackZh: string;
  expectedDisplay: string;
};

type GradeResult = {
  overall: 'correct' | 'partial' | 'incorrect';
  score: number; // 所有 blank score 的算术平均，0..1
  perBlank: BlankGradeResult[];
  submittedAt: EpochMs;
};

type ExerciseAttemptDraft = {
  attemptId: Id;
  exerciseId: Id;
  startedAt: EpochMs;
  answers: ConfirmedAnswer[];
};

interface ExerciseRepository {
  getExercise(exerciseId: Id): Promise<ExerciseDetail>;
  createDraft(exerciseId: Id): Promise<ExerciseAttemptDraft>;
  saveGrade(attemptId: Id, result: GradeResult): Promise<void>;
}

interface GradingService {
  grade(exerciseId: Id, answers: ConfirmedAnswer[]): Promise<GradeResult>;
}
```

纯判分引擎无 IO：

```ts
type ExerciseRules = {
  blanks: ExerciseBlank[];
  gradingOptions: ExerciseDetail['gradingOptions'];
  rules: JsonObject[];
};

interface GradingEngine {
  grade(rules: ExerciseRules, answers: ConfirmedAnswer[]): GradeResult;
}
```

## 7. 复习 DTO

```ts
type ReviewRating = 0 | 1 | 2 | 3;

type ReviewCard = {
  id: Id;
  bookId: Id;
  chapterId: Id;
  sourceType: 'package' | 'wrong-item';
  sourceId: string;
  front: JsonObject;
  back: JsonObject;
  state: 'new' | 'learning' | 'review' | 'suspended';
  dueAt: EpochMs;
  intervalDays: number;
  easeFactor: number;
  lapses: number;
};

type CreateReviewCardInput = {
  bookId: Id;
  chapterId: Id;
  sourceType: 'package' | 'wrong-item';
  sourceId: string;
  front: JsonObject;
  back: JsonObject;
  createdAt: EpochMs;
};

type ScheduleResult = {
  cardId: Id;
  previousState: ReviewCard['state'];
  nextState: ReviewCard['state'];
  previousDueAt: EpochMs;
  nextDueAt: EpochMs;
  previousIntervalDays: number;
  nextIntervalDays: number;
  previousEaseFactor: number;
  nextEaseFactor: number;
};

type ReviewSession = {
  sessionId: Id;
  cardIds: Id[];
  currentIndex: number;
  startedAt: EpochMs;
};

type TodayReviewSummary = {
  dueCount: number;       // 今日到期卡片数
  completedCount: number; // 今日已完成（review_logs.reviewed_at 落在当日）
  dailyGoal: number;      // review.dailyGoal 设置值
};

interface ReviewRepository {
  upsertFromSource(input: CreateReviewCardInput): Promise<ReviewCard>;
  getDue(now: EpochMs, bookId?: Id): Promise<ReviewCard[]>;
  get(cardId: Id): Promise<ReviewCard>;
}

interface ReviewScheduler {
  createSession(now: EpochMs, bookId?: Id): Promise<ReviewSession>;
  applyRating(cardId: Id, rating: ReviewRating, now: EpochMs): Promise<ScheduleResult>;
  getTodaySummary(now: EpochMs, bookId?: Id): Promise<TodayReviewSummary>;
}
```

「一次复习会话内卡片去重」由 `createSession` 在会话内自持已出现卡片集合实现，属会话层内存状态，
不暴露为独立接口（满足 F09 验收『同一张卡不会在一次复习会话中无理由重复』，R-053）。

## 8. 批注 DTO（F08，R-051）

```ts
type RelocationState = 'stable' | 'needs-relocation' | 'orphaned';

type AnnotationAnchor = {
  sectionId?: Id;
  blockId?: Id;
  rangeStart?: number;     // 文本高亮字符起点（与 highlights.range_start 对应）
  rangeEnd?: number;       // 文本高亮字符终点
  quoteText?: string;      // 锚定文本，升级重定位用
  coordinate?: JsonObject; // 手写笔记画布坐标
};

type Note = {
  id: Id;
  bookId: Id;
  chapterId: Id;
  sectionId?: Id;
  blockId?: Id;
  type: 'handwriting' | 'text';
  textContent: string;
  anchor: AnnotationAnchor;
  color: string;               // #RRGGBB
  relocationState: RelocationState;
  strokeRecordId?: Id;         // type='handwriting' 时关联 handwriting_records
  createdAt: EpochMs;
  updatedAt: EpochMs;
};

type Highlight = {
  id: Id;
  bookId: Id;
  chapterId: Id;
  blockId: Id;
  rangeStart: number;
  rangeEnd: number;            // > rangeStart 且 ≤ 保存时 plainText 长度
  quoteText: string;
  color: string;
  relocationState: RelocationState;
  createdAt: EpochMs;
};

type Bookmark = {
  id: Id;
  bookId: Id;
  chapterId: Id;
  blockId?: Id;                // scope='chapter' 时为空
  scope: 'chapter' | 'block';
  label: string;
  createdAt: EpochMs;
};

type SaveNoteInput = {
  id?: Id;                     // 省略=新建，传入=更新
  bookId: Id;
  chapterId: Id;
  sectionId?: Id;
  blockId?: Id;
  type: 'handwriting' | 'text';
  textContent: string;
  anchor: AnnotationAnchor;
  color: string;
  strokeRecordId?: Id;
};

type CreateHighlightInput = {
  bookId: Id;
  chapterId: Id;
  blockId: Id;
  rangeStart: number;
  rangeEnd: number;
  quoteText: string;
  color: string;
};

type ToggleBookmarkInput = {
  bookId: Id;
  chapterId: Id;
  blockId?: Id;
  scope: 'chapter' | 'block';
  label?: string;
};

type AnnotationListQuery = {
  bookId: Id;
  chapterId?: Id;
  includeRelocation?: boolean; // 默认 false：仅 stable；true 时含 needs-relocation/orphaned
};

interface AnnotationRepository {
  listNotes(query: AnnotationListQuery): Promise<Note[]>;
  listHighlights(query: AnnotationListQuery): Promise<Highlight[]>;
  listBookmarks(query: AnnotationListQuery): Promise<Bookmark[]>;
  saveNote(input: SaveNoteInput): Promise<Note>;
  createHighlight(input: CreateHighlightInput): Promise<Highlight>;
  toggleBookmark(input: ToggleBookmarkInput): Promise<Bookmark | null>; // 已存在则移除并返回 null
  softDeleteNote(noteId: Id): Promise<void>;       // 写 notes.deleted_at
  softDeleteHighlight(highlightId: Id): Promise<void>;
  removeBookmark(bookmarkId: Id): Promise<void>;   // bookmarks 无软删除列，物理删除
  listNeedingRelocation(bookId: Id): Promise<{ notes: Note[]; highlights: Highlight[] }>;
  relocate(target: 'note' | 'highlight', id: Id, anchor: AnnotationAnchor): Promise<void>;
}

interface AnnotationService {
  scheduleAutoSave(input: SaveNoteInput): void;     // 内存缓冲 + 周期快照（HLD §5.8 / FR-F08-05）
  flush(bookId: Id, chapterId: Id): Promise<void>;  // 页面退出前强制落盘
  createHighlight(input: CreateHighlightInput): Promise<Highlight>;
  eraseHighlight(highlightId: Id): Promise<void>;
  toggleBookmark(input: ToggleBookmarkInput): Promise<Bookmark | null>;
  listRelocations(bookId: Id): Promise<{ notes: Note[]; highlights: Highlight[] }>;
  relocateNote(noteId: Id, anchor: AnnotationAnchor): Promise<void>;
  relocateHighlight(highlightId: Id, anchor: AnnotationAnchor): Promise<void>;
}
```

手写笔记的笔迹采集、橡皮擦与撤销由 `HandwritingService` 的 `StrokeSession`（§5）承载；
`AnnotationService` 只负责文本/锚点的自动保存编排与升级后重定位。

## 9. 错题本与统计 DTO（F10/F11，R-052）

```ts
type WrongItemErrorType =
  | 'missing-auxiliary'
  | 'wrong-tense'
  | 'wrong-form'
  | 'spelling'
  | 'missing-word'
  | 'extra-word'
  | 'word-order'
  | 'recognition-uncertain'
  | 'other';

type WrongItemStatus = 'active' | 'mastered' | 'dismissed';

type WrongItemFilter = {
  bookId?: Id;          // 省略=全部书籍
  chapterId?: Id;
  grammarPoint?: string;
  errorType?: WrongItemErrorType;
  status?: WrongItemStatus; // 省略默认 'active'
  since?: EpochMs;
  until?: EpochMs;
};

type WrongItemSummary = {
  id: Id;
  exerciseId: Id;
  bookId: Id;
  chapterId: Id;
  errorType: WrongItemErrorType;
  errorCount: number;
  correctStreak: number;
  status: WrongItemStatus;
  nextDueAt?: EpochMs;
  updatedAt: EpochMs;
};

type WrongItemDetail = WrongItemSummary & {
  exercise: ExerciseDetail;
  latestAnswers: ConfirmedAnswer[];   // 用户答案（FR-F10-03）
  latestResult: GradeResult;          // 逐空对错与错误原因
};

type StatRange = 'day' | 'week' | 'month';

type StatsResult = {
  range: StatRange;
  bookId?: Id;
  activeStudyMs: number;          // 有效学习时长（learning_events 派生）
  studiedDays: number;
  currentStreakDays: number;      // 连续学习天数（按设备本地时区，见 LLD §3.13.1/§3.13A 口径）
  exerciseAttempted: number;
  exerciseCorrectRate: number;    // 0..1
  reviewCompleted: number;
  masteredCount: number;
  weakPoints: Array<{ grammarPoint: string; errorCount: number }>;
  perDay: Array<{ date: string; activeStudyMs: number; correctRate: number }>; // date 为 YYYY-MM-DD
  computedAt: EpochMs;
};

type LearningEventInput = {
  bookId: Id;
  chapterId?: Id;
  type: 'open' | 'active' | 'pause';
  occurredAt: EpochMs;
  activeDurationMs?: number;      // type='active' 时的心跳时长
};

interface WrongBookRepository {
  query(filter: WrongItemFilter): Promise<WrongItemSummary[]>;
  getDetail(wrongItemId: Id): Promise<WrongItemDetail>;
  listForBatch(filter: WrongItemFilter, limit: number): Promise<Id[]>; // 批量练习的 exerciseId 列表
  markMastered(wrongItemId: Id): Promise<void>;  // 仅置 status='mastered'，不覆盖 exercise_attempts 历史
}

interface StatisticsService {
  recordEvent(input: LearningEventInput): Promise<void>; // learning_events 唯一写入口（LLD §3.13）
  getMetrics(range: StatRange, bookId?: Id): Promise<StatsResult>;
  recompute(bookId?: Id): Promise<StatsResult>; // 从原始 events/attempts/review_logs 重算（FR-F11-05）
}
```

统计指标一律由 `StatisticsService` 从原始事件重算，页面不得自行累加（HLD §5.11，R-052）。

## 10. 设置 DTO（F12，R-053）

```ts
type SettingsKey =
  | 'handwriting.penColor'
  | 'handwriting.penWidth'
  | 'recognition.failureAction'
  | 'review.dailyGoal'
  | 'reading.fontScale'
  | 'wrongbook.masteryStreak';

// 键到值类型的映射，与 LLD §3.24 user_settings 第一版键一致
type SettingsValueMap = {
  'handwriting.penColor': string;                  // #RRGGBB
  'handwriting.penWidth': number;                  // 0.5..20
  'recognition.failureAction': 'retry' | 'rewrite';
  'review.dailyGoal': number;                      // 1..500
  'reading.fontScale': number;                     // 0.8..1.6
  'wrongbook.masteryStreak': number;               // 1..10
};

interface SettingsService {
  get<K extends SettingsKey>(key: K): Promise<SettingsValueMap[K]>;
  getAll(): Promise<SettingsValueMap>;
  set<K extends SettingsKey>(key: K, value: SettingsValueMap[K]): Promise<void>; // 键级校验，越界/非法拒绝
}
```

`set` 必须按 `SettingsValueMap` 与 LLD §3.24 约束做键级校验，校验失败抛可转 `AppError` 的领域错误，
不写库（HLD §5.12『写入必须经过键级校验』，R-053）。

## 11. 备份 DTO

```ts
type ExportOptions = {
  includeBooks: boolean;
  includeProgress: boolean;
  includeAttempts: boolean;
  includeHandwriting: boolean;
  includeNotes: boolean;
};

type BackupValidationResult = {
  compatible: boolean;
  formatVersion: string;
  createdAt: EpochMs;
  bookCount: number;
  estimatedExpandedBytes: number;
  warnings: AppError[];
  blockingErrors: AppError[];
};

type RestoreMode = 'merge' | 'replace-all';

interface BackupService {
  export(options: ExportOptions): Promise<string>;
  validateBackup(uri: string): Promise<BackupValidationResult>;
  restore(uri: string, mode: RestoreMode): Promise<void>;
}
```

## 12. 契约一致性规则

1. `GradingService` 负责异步取数和持久化编排；`GradingEngine` 是同步纯函数。
2. 多空题必须返回 `perBlank`，整体得分为各空分数算术平均。
3. 识别失败不构造 `ConfirmedAnswer`，也不调用 `GradingService`。
4. `ReviewRepository.upsertFromSource` 是创建复习卡的唯一入口。
5. 页面只能依赖 Service/ViewModel，不直接持有数据库事务或文件路径。
6. `learning_events` 的唯一写入口是 `StatisticsService.recordEvent`；统计指标全部由 `StatisticsService` 重算，页面与错题本不得自行累加（R-052）。
7. `WrongBookRepository.markMastered` 只改 `wrong_items.status`，绝不覆盖或删除 `exercise_attempts` 历史（R-052）。
8. `SettingsService.set` 必须按 `SettingsValueMap` 与 LLD §3.24 做键级校验后才落库（R-053）。
9. 笔迹采集/橡皮擦/撤销归 `HandwritingService.StrokeSession`；`AnnotationService` 只编排文本批注的自动保存、退出落盘与升级重定位（R-051）。
