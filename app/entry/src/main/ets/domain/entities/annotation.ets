/**
 * 批注 DTO 契约（《04-接口与DTO契约》§8，F08 / R-051）。
 * 适配 ArkTS：listNeedingRelocation / listRelocations 的内联返回对象拆为具名接口 RelocationList，字段集不变。
 * AnnotationService 只编排文本批注的自动保存、退出落盘与升级重定位；笔迹采集/橡皮擦/撤销归 HandwritingService（04 §12 规则9）。
 */
import { Id, EpochMs, JsonObject } from './common';

/** 锚点重定位状态。 */
export type RelocationState = 'stable' | 'needs-relocation' | 'orphaned';

/** 批注锚点。 */
export interface AnnotationAnchor {
  /** 小节 ID（可选）。 */
  sectionId?: Id;
  /** 内容块 ID（可选）。 */
  blockId?: Id;
  /** 文本高亮字符起点（对应 highlights.range_start）。 */
  rangeStart?: number;
  /** 文本高亮字符终点。 */
  rangeEnd?: number;
  /** 锚定文本（升级重定位用）。 */
  quoteText?: string;
  /** 手写笔记画布坐标（可选）。 */
  coordinate?: JsonObject;
}

/** 笔记。 */
export interface Note {
  /** 笔记 ID。 */
  id: Id;
  /** 书籍 ID。 */
  bookId: Id;
  /** 章节 ID。 */
  chapterId: Id;
  /** 小节 ID（可选）。 */
  sectionId?: Id;
  /** 内容块 ID（可选）。 */
  blockId?: Id;
  /** 笔记类型。 */
  type: 'handwriting' | 'text';
  /** 文本内容。 */
  textContent: string;
  /** 锚点。 */
  anchor: AnnotationAnchor;
  /** 颜色 #RRGGBB。 */
  color: string;
  /** 重定位状态。 */
  relocationState: RelocationState;
  /** type='handwriting' 时关联 handwriting_records。 */
  strokeRecordId?: Id;
  /** 创建时间。 */
  createdAt: EpochMs;
  /** 更新时间。 */
  updatedAt: EpochMs;
}

/** 高亮。 */
export interface Highlight {
  /** 高亮 ID。 */
  id: Id;
  /** 书籍 ID。 */
  bookId: Id;
  /** 章节 ID。 */
  chapterId: Id;
  /** 内容块 ID。 */
  blockId: Id;
  /** 字符起点。 */
  rangeStart: number;
  /** 字符终点（> rangeStart 且 ≤ 保存时 plainText 长度）。 */
  rangeEnd: number;
  /** 锚定文本。 */
  quoteText: string;
  /** 颜色 #RRGGBB。 */
  color: string;
  /** 重定位状态。 */
  relocationState: RelocationState;
  /** 创建时间。 */
  createdAt: EpochMs;
}

/** 书签。 */
export interface Bookmark {
  /** 书签 ID。 */
  id: Id;
  /** 书籍 ID。 */
  bookId: Id;
  /** 章节 ID。 */
  chapterId: Id;
  /** 内容块 ID（scope='chapter' 时为空）。 */
  blockId?: Id;
  /** 作用域。 */
  scope: 'chapter' | 'block';
  /** 标签。 */
  label: string;
  /** 创建时间。 */
  createdAt: EpochMs;
}

/** 保存笔记输入（省略 id=新建，传入=更新）。 */
export interface SaveNoteInput {
  /** 笔记 ID（省略=新建）。 */
  id?: Id;
  /** 书籍 ID。 */
  bookId: Id;
  /** 章节 ID。 */
  chapterId: Id;
  /** 小节 ID（可选）。 */
  sectionId?: Id;
  /** 内容块 ID（可选）。 */
  blockId?: Id;
  /** 笔记类型。 */
  type: 'handwriting' | 'text';
  /** 文本内容。 */
  textContent: string;
  /** 锚点。 */
  anchor: AnnotationAnchor;
  /** 颜色 #RRGGBB。 */
  color: string;
  /** 关联笔迹记录（可选）。 */
  strokeRecordId?: Id;
}

/** 创建高亮输入。 */
export interface CreateHighlightInput {
  /** 书籍 ID。 */
  bookId: Id;
  /** 章节 ID。 */
  chapterId: Id;
  /** 内容块 ID。 */
  blockId: Id;
  /** 字符起点。 */
  rangeStart: number;
  /** 字符终点。 */
  rangeEnd: number;
  /** 锚定文本。 */
  quoteText: string;
  /** 颜色 #RRGGBB。 */
  color: string;
}

/** 切换书签输入（已存在则移除）。 */
export interface ToggleBookmarkInput {
  /** 书籍 ID。 */
  bookId: Id;
  /** 章节 ID。 */
  chapterId: Id;
  /** 内容块 ID（可选）。 */
  blockId?: Id;
  /** 作用域。 */
  scope: 'chapter' | 'block';
  /** 标签（可选）。 */
  label?: string;
}

/** 批注列表查询。 */
export interface AnnotationListQuery {
  /** 书籍 ID。 */
  bookId: Id;
  /** 章节 ID（可选）。 */
  chapterId?: Id;
  /** 默认 false 仅 stable；true 含 needs-relocation/orphaned。 */
  includeRelocation?: boolean;
}

/** 待重定位批注集合（替代 04 内联返回对象，字段集不变）。 */
export interface RelocationList {
  /** 待重定位笔记。 */
  notes: Note[];
  /** 待重定位高亮。 */
  highlights: Highlight[];
}

/** 批注仓储契约。 */
export interface AnnotationRepository {
  /**
   * 列出笔记。
   * @param query 列表查询
   * @returns 笔记数组
   */
  listNotes(query: AnnotationListQuery): Promise<Note[]>;
  /**
   * 列出高亮。
   * @param query 列表查询
   * @returns 高亮数组
   */
  listHighlights(query: AnnotationListQuery): Promise<Highlight[]>;
  /**
   * 列出书签。
   * @param query 列表查询
   * @returns 书签数组
   */
  listBookmarks(query: AnnotationListQuery): Promise<Bookmark[]>;
  /**
   * 保存笔记。
   * @param input 保存输入
   * @returns 笔记
   */
  saveNote(input: SaveNoteInput): Promise<Note>;
  /**
   * 创建高亮。
   * @param input 创建输入
   * @returns 高亮
   */
  createHighlight(input: CreateHighlightInput): Promise<Highlight>;
  /**
   * 切换书签；已存在则移除并返回 null。
   * @param input 切换输入
   * @returns 书签或 null
   */
  toggleBookmark(input: ToggleBookmarkInput): Promise<Bookmark | null>;
  /**
   * 软删除笔记（写 notes.deleted_at）。
   * @param noteId 笔记 ID
   */
  softDeleteNote(noteId: Id): Promise<void>;
  /**
   * 软删除高亮。
   * @param highlightId 高亮 ID
   */
  softDeleteHighlight(highlightId: Id): Promise<void>;
  /**
   * 移除书签（bookmarks 无软删列，物理删除）。
   * @param bookmarkId 书签 ID
   */
  removeBookmark(bookmarkId: Id): Promise<void>;
  /**
   * 列出待重定位批注。
   * @param bookId 书籍 ID
   * @returns 待重定位集合
   */
  listNeedingRelocation(bookId: Id): Promise<RelocationList>;
  /**
   * 重定位批注锚点。
   * @param target 目标类型
   * @param id 批注 ID
   * @param anchor 新锚点
   */
  relocate(target: 'note' | 'highlight', id: Id, anchor: AnnotationAnchor): Promise<void>;
}

/** 批注服务契约（自动保存编排、退出落盘、升级重定位，04 §12 规则9）。 */
export interface AnnotationService {
  /**
   * 自动保存编排（内存缓冲 + 周期快照，HLD §5.8 / FR-F08-05）。
   * @param input 保存输入
   */
  scheduleAutoSave(input: SaveNoteInput): void;
  /**
   * 页面退出前强制落盘。
   * @param bookId 书籍 ID
   * @param chapterId 章节 ID
   */
  flush(bookId: Id, chapterId: Id): Promise<void>;
  /**
   * 创建高亮。
   * @param input 创建输入
   * @returns 高亮
   */
  createHighlight(input: CreateHighlightInput): Promise<Highlight>;
  /**
   * 擦除高亮。
   * @param highlightId 高亮 ID
   */
  eraseHighlight(highlightId: Id): Promise<void>;
  /**
   * 切换书签；已存在则移除并返回 null。
   * @param input 切换输入
   * @returns 书签或 null
   */
  toggleBookmark(input: ToggleBookmarkInput): Promise<Bookmark | null>;
  /**
   * 列出待重定位批注。
   * @param bookId 书籍 ID
   * @returns 待重定位集合
   */
  listRelocations(bookId: Id): Promise<RelocationList>;
  /**
   * 重定位笔记。
   * @param noteId 笔记 ID
   * @param anchor 新锚点
   */
  relocateNote(noteId: Id, anchor: AnnotationAnchor): Promise<void>;
  /**
   * 重定位高亮。
   * @param highlightId 高亮 ID
   * @param anchor 新锚点
   */
  relocateHighlight(highlightId: Id, anchor: AnnotationAnchor): Promise<void>;
}
