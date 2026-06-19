# 墨学书架接口与 DTO 契约

| 项目 | 内容 |
|---|---|
| 文档编号 | MX-API-001 |
| 版本 | 1.1.0 |
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

第一版只支持手写题型：

```ts
type ExerciseType =
  | 'fill-blank-handwriting'
  | 'multi-blank-handwriting'
  | 'rewrite-sentence-handwriting'
  | 'short-answer-handwriting'
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

interface ReviewRepository {
  upsertFromSource(input: CreateReviewCardInput): Promise<ReviewCard>;
  getDue(now: EpochMs, bookId?: Id): Promise<ReviewCard[]>;
  get(cardId: Id): Promise<ReviewCard>;
}

interface ReviewScheduler {
  createSession(now: EpochMs, bookId?: Id): Promise<ReviewSession>;
  applyRating(cardId: Id, rating: ReviewRating, now: EpochMs): Promise<ScheduleResult>;
}
```

## 8. 备份 DTO

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

## 9. 契约一致性规则

1. `GradingService` 负责异步取数和持久化编排；`GradingEngine` 是同步纯函数。
2. 多空题必须返回 `perBlank`，整体得分为各空分数算术平均。
3. 识别失败不构造 `ConfirmedAnswer`，也不调用 `GradingService`。
4. `ReviewRepository.upsertFromSource` 是创建复习卡的唯一入口。
5. 页面只能依赖 Service/ViewModel，不直接持有数据库事务或文件路径。
