/**
 * 阅读进度 DTO 契约（《04-接口与DTO契约》§4）。
 */
import { Id, EpochMs, JsonObject } from './common';

/** 章节阅读进度。 */
export interface ReadingProgress {
  /** 书籍 ID。 */
  bookId: Id;
  /** 章节 ID。 */
  chapterId: Id;
  /** 进度状态（有自然初值 'not-started'，LLD §1.3 / §3.39）。 */
  status: 'not-started' | 'learning' | 'completed' | 'review-due';
  /** 完成百分比 0..100。 */
  completionPercent: number;
  /** 上次小节 ID（可选）。 */
  lastSectionId?: Id;
  /** 上次内容块 ID（可选）。 */
  lastBlockId?: Id;
  /** 滚动锚点（恢复定位）。 */
  scrollAnchor: JsonObject;
  /** 首次打开时间。 */
  firstOpenedAt?: EpochMs;
  /** 上次打开时间。 */
  lastOpenedAt?: EpochMs;
  /** 完成时间。 */
  completedAt?: EpochMs;
}

/** 保存阅读锚点输入。 */
export interface SaveReadingAnchorInput {
  /** 书籍 ID。 */
  bookId: Id;
  /** 章节 ID。 */
  chapterId: Id;
  /** 小节 ID（可选）。 */
  sectionId?: Id;
  /** 内容块 ID（可选）。 */
  blockId?: Id;
  /** 滚动锚点。 */
  scrollAnchor: JsonObject;
  /** 本次有效学习时长（毫秒）。 */
  activeDurationMs: number;
  /** 保存时间。 */
  savedAt: EpochMs;
}

/** 小节已读证据（完成度判定，LLD §3.13）。 */
export interface SectionReadEvidence {
  /** 书籍 ID。 */
  bookId: Id;
  /** 章节 ID。 */
  chapterId: Id;
  /** 小节 ID。 */
  sectionId: Id;
  /** 最大可见比例 0..1。 */
  maxVisibleRatio: number;
  /** 有效学习时长（毫秒）。 */
  activeDurationMs: number;
  /** 是否前往下一小节或练习。 */
  leftForNextSectionOrExercise: boolean;
  /** 观察时间。 */
  observedAt: EpochMs;
}

/** 进度仓储契约。 */
export interface ProgressRepository {
  /**
   * 取章节进度。
   * @param bookId 书籍 ID
   * @param chapterId 章节 ID
   * @returns 阅读进度
   */
  getChapterProgress(bookId: Id, chapterId: Id): Promise<ReadingProgress>;
  /**
   * 保存阅读锚点。
   * @param input 锚点输入
   */
  saveAnchor(input: SaveReadingAnchorInput): Promise<void>;
  /**
   * 保存小节已读证据。
   * @param input 证据输入
   */
  saveSectionEvidence(input: SectionReadEvidence): Promise<void>;
}

/** 进度服务契约。 */
export interface ProgressService {
  /**
   * 重算章节进度。
   * @param bookId 书籍 ID
   * @param chapterId 章节 ID
   * @returns 阅读进度
   */
  recomputeChapter(bookId: Id, chapterId: Id): Promise<ReadingProgress>;
  /**
   * 重算全书完成度。
   * @param bookId 书籍 ID
   * @returns 完成百分比 0..100
   */
  recomputeBook(bookId: Id): Promise<number>;
}
