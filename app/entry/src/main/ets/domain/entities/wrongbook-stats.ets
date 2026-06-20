/**
 * 错题本与统计 DTO 契约（《04-接口与DTO契约》§9，F10/F11 / R-052）。
 * 适配 ArkTS：04 中 WrongItemDetail 的交叉类型改用 interface extends；StatsResult 内联数组对象拆为
 * 具名接口 WeakPoint / DailyStat，字段集不变。
 * 统计指标一律由 StatisticsService 从原始事件重算，页面与错题本不得自行累加（04 §12 规则6）。
 */
import { Id, EpochMs } from './common';
import { ExerciseDetail, ConfirmedAnswer, GradeResult } from './exercise';

/** 错误类型受控词表（《06》§错误分类）。 */
export type WrongItemErrorType =
  | 'missing-auxiliary'
  | 'wrong-tense'
  | 'wrong-form'
  | 'spelling'
  | 'missing-word'
  | 'extra-word'
  | 'word-order'
  | 'recognition-uncertain'
  | 'other';

/** 错题状态。 */
export type WrongItemStatus = 'active' | 'mastered' | 'dismissed';

/** 错题筛选条件。 */
export interface WrongItemFilter {
  /** 书籍 ID（省略=全部书籍）。 */
  bookId?: Id;
  /** 章节 ID（可选）。 */
  chapterId?: Id;
  /** 语法点（可选）。 */
  grammarPoint?: string;
  /** 错误类型（可选）。 */
  errorType?: WrongItemErrorType;
  /** 状态（省略默认 'active'）。 */
  status?: WrongItemStatus;
  /** 起始时间（可选）。 */
  since?: EpochMs;
  /** 截止时间（可选）。 */
  until?: EpochMs;
}

/** 错题摘要。 */
export interface WrongItemSummary {
  /** 错题 ID。 */
  id: Id;
  /** 练习 ID。 */
  exerciseId: Id;
  /** 书籍 ID。 */
  bookId: Id;
  /** 章节 ID。 */
  chapterId: Id;
  /** 错误类型。 */
  errorType: WrongItemErrorType;
  /** 错误次数。 */
  errorCount: number;
  /** 连续正确次数。 */
  correctStreak: number;
  /** 状态。 */
  status: WrongItemStatus;
  /** 下次到期时间（可选）。 */
  nextDueAt?: EpochMs;
  /** 更新时间。 */
  updatedAt: EpochMs;
}

/** 错题详情（在摘要基础上补充练习与最近作答）。 */
export interface WrongItemDetail extends WrongItemSummary {
  /** 练习详情。 */
  exercise: ExerciseDetail;
  /** 用户最近答案（FR-F10-03）。 */
  latestAnswers: ConfirmedAnswer[];
  /** 逐空对错与错误原因。 */
  latestResult: GradeResult;
}

/** 统计区间。 */
export type StatRange = 'day' | 'week' | 'month';

/** 薄弱点（语法点 → 错误次数）。 */
export interface WeakPoint {
  /** 语法点。 */
  grammarPoint: string;
  /** 错误次数。 */
  errorCount: number;
}

/** 每日统计项。 */
export interface DailyStat {
  /** 日期 YYYY-MM-DD（设备本地时区）。 */
  date: string;
  /** 当日有效学习时长（毫秒）。 */
  activeStudyMs: number;
  /** 当日正确率 0..1。 */
  correctRate: number;
}

/** 统计结果。 */
export interface StatsResult {
  /** 统计区间。 */
  range: StatRange;
  /** 书籍 ID（可选）。 */
  bookId?: Id;
  /** 有效学习时长（learning_events 派生）。 */
  activeStudyMs: number;
  /** 学习天数。 */
  studiedDays: number;
  /** 连续学习天数（设备本地时区，LLD §3.13.1/§3.13A）。 */
  currentStreakDays: number;
  /** 练习作答数。 */
  exerciseAttempted: number;
  /** 练习正确率 0..1。 */
  exerciseCorrectRate: number;
  /** 完成复习数。 */
  reviewCompleted: number;
  /** 已掌握数。 */
  masteredCount: number;
  /** 薄弱点列表。 */
  weakPoints: WeakPoint[];
  /** 每日明细。 */
  perDay: DailyStat[];
  /** 计算时间。 */
  computedAt: EpochMs;
}

/** 学习事件输入。 */
export interface LearningEventInput {
  /** 书籍 ID。 */
  bookId: Id;
  /** 章节 ID（可选）。 */
  chapterId?: Id;
  /** 事件类型。 */
  type: 'open' | 'active' | 'pause';
  /** 发生时间。 */
  occurredAt: EpochMs;
  /** type='active' 时的心跳时长（毫秒）。 */
  activeDurationMs?: number;
}

/** 错题本仓储契约。 */
export interface WrongBookRepository {
  /**
   * 条件查询错题。
   * @param filter 筛选条件
   * @returns 错题摘要数组
   */
  query(filter: WrongItemFilter): Promise<WrongItemSummary[]>;
  /**
   * 取错题详情。
   * @param wrongItemId 错题 ID
   * @returns 错题详情
   */
  getDetail(wrongItemId: Id): Promise<WrongItemDetail>;
  /**
   * 取批量练习的 exerciseId 列表。
   * @param filter 筛选条件
   * @param limit 数量上限
   * @returns 练习 ID 数组
   */
  listForBatch(filter: WrongItemFilter, limit: number): Promise<Id[]>;
  /**
   * 仅置 status='mastered'，绝不覆盖或删除 exercise_attempts 历史（R-052）。
   * @param wrongItemId 错题 ID
   */
  markMastered(wrongItemId: Id): Promise<void>;
}

/** 统计服务契约。 */
export interface StatisticsService {
  /**
   * 记录学习事件（learning_events 唯一写入口，LLD §3.13 / 04 §12 规则6）。
   * @param input 事件输入
   */
  recordEvent(input: LearningEventInput): Promise<void>;
  /**
   * 取统计指标。
   * @param range 统计区间
   * @param bookId 可选书籍过滤
   * @returns 统计结果
   */
  getMetrics(range: StatRange, bookId?: Id): Promise<StatsResult>;
  /**
   * 从原始 events/attempts/review_logs 重算（FR-F11-05）。
   * @param bookId 可选书籍过滤
   * @returns 统计结果
   */
  recompute(bookId?: Id): Promise<StatsResult>;
}
