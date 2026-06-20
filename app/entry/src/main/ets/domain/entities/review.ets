/**
 * 复习 DTO 契约（《04-接口与DTO契约》§7）。
 * 适配 ArkTS：04 中 ScheduleResult 的索引访问类型 ReviewCard['state'] 改为引用具名类型 ReviewCardState。
 * 会话内卡片去重由 createSession 自持已出现集合实现（R-053），不暴露为独立接口。
 */
import { Id, EpochMs, JsonObject } from './common';

/** 复习评分（0 忘记 .. 3 简单）。 */
export type ReviewRating = 0 | 1 | 2 | 3;

/** 复习卡状态（拆名以替代 04 的 ReviewCard['state'] 索引访问）。 */
export type ReviewCardState = 'new' | 'learning' | 'review' | 'suspended';

/** 复习卡。 */
export interface ReviewCard {
  /** 复习卡 ID。 */
  id: Id;
  /** 书籍 ID。 */
  bookId: Id;
  /** 章节 ID。 */
  chapterId: Id;
  /** 来源类型。 */
  sourceType: 'package' | 'wrong-item';
  /** 来源 ID。 */
  sourceId: string;
  /** 正面载体。 */
  front: JsonObject;
  /** 背面载体。 */
  back: JsonObject;
  /** 卡片状态。 */
  state: ReviewCardState;
  /** 到期时间。 */
  dueAt: EpochMs;
  /** 当前间隔（天）。 */
  intervalDays: number;
  /** 易度因子。 */
  easeFactor: number;
  /** 遗忘次数。 */
  lapses: number;
}

/** 创建复习卡输入（upsertFromSource 是唯一创建入口，04 §12 规则4）。 */
export interface CreateReviewCardInput {
  /** 书籍 ID。 */
  bookId: Id;
  /** 章节 ID。 */
  chapterId: Id;
  /** 来源类型。 */
  sourceType: 'package' | 'wrong-item';
  /** 来源 ID。 */
  sourceId: string;
  /** 正面载体。 */
  front: JsonObject;
  /** 背面载体。 */
  back: JsonObject;
  /** 创建时间。 */
  createdAt: EpochMs;
}

/** 调度结果（评分后状态迁移前后值）。 */
export interface ScheduleResult {
  /** 复习卡 ID。 */
  cardId: Id;
  /** 迁移前状态。 */
  previousState: ReviewCardState;
  /** 迁移后状态。 */
  nextState: ReviewCardState;
  /** 迁移前到期时间。 */
  previousDueAt: EpochMs;
  /** 迁移后到期时间。 */
  nextDueAt: EpochMs;
  /** 迁移前间隔（天）。 */
  previousIntervalDays: number;
  /** 迁移后间隔（天）。 */
  nextIntervalDays: number;
  /** 迁移前易度因子。 */
  previousEaseFactor: number;
  /** 迁移后易度因子。 */
  nextEaseFactor: number;
}

/** 复习会话（会话内自持去重集合，04 §7 / R-053）。 */
export interface ReviewSession {
  /** 会话 ID。 */
  sessionId: Id;
  /** 卡片 ID 列表。 */
  cardIds: Id[];
  /** 当前索引。 */
  currentIndex: number;
  /** 开始时间。 */
  startedAt: EpochMs;
}

/** 今日复习摘要。 */
export interface TodayReviewSummary {
  /** 今日到期卡片数。 */
  dueCount: number;
  /** 今日已完成（review_logs.reviewed_at 落当日）。 */
  completedCount: number;
  /** review.dailyGoal 设置值。 */
  dailyGoal: number;
}

/** 复习仓储契约。 */
export interface ReviewRepository {
  /**
   * 由来源 upsert 复习卡（唯一创建入口）。
   * @param input 创建输入
   * @returns 复习卡
   */
  upsertFromSource(input: CreateReviewCardInput): Promise<ReviewCard>;
  /**
   * 取到期卡片。
   * @param now 当前时间
   * @param bookId 可选书籍过滤
   * @returns 复习卡数组
   */
  getDue(now: EpochMs, bookId?: Id): Promise<ReviewCard[]>;
  /**
   * 取单卡。
   * @param cardId 复习卡 ID
   * @returns 复习卡
   */
  get(cardId: Id): Promise<ReviewCard>;
}

/** 复习调度器契约。 */
export interface ReviewScheduler {
  /**
   * 创建复习会话（会话内去重）。
   * @param now 当前时间
   * @param bookId 可选书籍过滤
   * @returns 复习会话
   */
  createSession(now: EpochMs, bookId?: Id): Promise<ReviewSession>;
  /**
   * 应用评分并调度（间隔算法 LLD §5）。
   * @param cardId 复习卡 ID
   * @param rating 评分
   * @param now 当前时间
   * @returns 调度结果
   */
  applyRating(cardId: Id, rating: ReviewRating, now: EpochMs): Promise<ScheduleResult>;
  /**
   * 取今日复习摘要。
   * @param now 当前时间
   * @param bookId 可选书籍过滤
   * @returns 今日复习摘要
   */
  getTodaySummary(now: EpochMs, bookId?: Id): Promise<TodayReviewSummary>;
}
