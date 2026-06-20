/**
 * 书籍与内容 DTO 契约（《04-接口与DTO契约》§3）。
 * 适配 ArkTS：04 中 BookDetail 的交叉类型（BookSummary & {...}）改用 interface extends，字段集不变；
 * BookSummary.continueTarget 的内联对象类型拆为具名接口 ContinueTarget。
 * 跨层命名映射约定（R-046）：DB 列 snake_case、DTO JSON 字段 camelCase、枚举值 kebab-case。
 */
import { Id, EpochMs, JsonObject } from './common';

/** 书籍状态。 */
export type BookStatus = 'ready' | 'updating' | 'broken' | 'deleted';

/** 章节类型。 */
export type ChapterKind = 'lesson' | 'review' | 'appendix' | 'answer-key' | 'index';

/** 续读目标定位（BookSummary.continueTarget，重启恢复用）。 */
export interface ContinueTarget {
  /** 续读章节。 */
  chapterId: Id;
  /** 续读小节（可选）。 */
  sectionId?: Id;
  /** 续读内容块（可选）。 */
  blockId?: Id;
}

/** 书架卡片摘要。 */
export interface BookSummary {
  /** 书籍内部 ID。 */
  id: Id;
  /** 学习包外部包 ID。 */
  packageId: string;
  /** 内容版本。 */
  contentVersion: string;
  /** 主标题。 */
  title: string;
  /** 副标题。 */
  subtitle: string;
  /** 作者列表。 */
  authors: string[];
  /** 封面沙箱相对路径（可选）。 */
  coverUri?: string;
  /** 章节数。 */
  chapterCount: number;
  /** 完成百分比 0..100，1 位小数。 */
  completionPercent: number;
  /** 书籍状态。 */
  status: BookStatus;
  /** 上次打开时间。 */
  lastOpenedAt?: EpochMs;
  /** 续读目标。 */
  continueTarget?: ContinueTarget;
}

/** 书籍详情（在摘要基础上补充描述与时间戳）。 */
export interface BookDetail extends BookSummary {
  /** 简介。 */
  description: string;
  /** 语言列表。 */
  languages: string[];
  /** 导入时间。 */
  importedAt: EpochMs;
  /** 更新时间。 */
  updatedAt: EpochMs;
}

/** 章节摘要（目录页）。 */
export interface ChapterSummary {
  /** 章节内部 ID。 */
  id: Id;
  /** 学习包外部章节 ID。 */
  externalId: string;
  /** 所属书籍 ID。 */
  bookId: Id;
  /** 章节序号。 */
  orderNo: number;
  /** 章节类型。 */
  kind: ChapterKind;
  /** 标题。 */
  title: string;
  /** 中文标题。 */
  titleZh: string;
  /** 预计学习时长（分钟）。 */
  estimatedMinutes: number;
  /** 完成百分比 0..100。 */
  completionPercent: number;
  /** 进度状态。 */
  progressStatus: 'not-started' | 'learning' | 'completed' | 'review-due';
  /** 复习状态。 */
  reviewStatus: 'unreviewed' | 'needs-review' | 'reviewed';
}

/** 内容块。 */
export interface ContentBlock {
  /** 内容块内部 ID。 */
  id: Id;
  /** 所属小节 ID。 */
  sectionId: Id;
  /** 块序号。 */
  orderNo: number;
  /** 块类型（11 种，含 bullet-list / audio-text，LLD §6.5 映射表）。 */
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
  /** 渲染载体（写库前解析-校验-重序列化）。 */
  payload: JsonObject;
  /** 去格式纯文本（搜索/高亮定位用）。 */
  plainText: string;
  /** 资源沙箱相对路径（可选）。 */
  assetUri?: string;
  /** 源 PDF 页码（仅溯源，不展示 PDF）。 */
  sourcePages: number[];
}

/** 小节内容。 */
export interface SectionContent {
  /** 小节内部 ID。 */
  id: Id;
  /** 学习包外部小节 ID。 */
  externalId: string;
  /** 小节类型（协议自定义）。 */
  type: string;
  /** 小节标题。 */
  title: string;
  /** 内容块列表。 */
  blocks: ContentBlock[];
}

/** 章节完整内容。 */
export interface ChapterContent {
  /** 章节摘要。 */
  chapter: ChapterSummary;
  /** 小节列表。 */
  sections: SectionContent[];
  /** 章节练习 ID 列表。 */
  exerciseIds: Id[];
}

/** 书架列表查询。 */
export interface BookListQuery {
  /** 排序方式。 */
  sort: 'last-opened' | 'title' | 'imported-at';
  /** 关键词过滤（可选）。 */
  keyword?: string;
  /** 是否包含损坏书籍（可选）。 */
  includeBroken?: boolean;
}

/** 章节搜索结果（章节级，F04 目录搜索）。 */
export interface SearchResult {
  /** 命中章节 ID。 */
  chapterId: Id;
  /** 学习包外部章节 ID。 */
  externalId: string;
  /** 标题。 */
  title: string;
  /** 中文标题。 */
  titleZh: string;
  /** 章节序号。 */
  orderNo: number;
  /** 命中字段。 */
  matchedField: 'title' | 'titleZh' | 'keyword';
  /** 命中文本片段。 */
  matchedText: string;
}

/** 书籍仓储契约（页面不直接执行 SQL，CLAUDE.md §5）。 */
export interface BooksRepository {
  /**
   * 列出书架书籍。
   * @param query 列表查询
   * @returns 书籍摘要数组
   */
  list(query: BookListQuery): Promise<BookSummary[]>;
  /**
   * 取书籍详情。
   * @param bookId 书籍 ID
   * @returns 书籍详情
   */
  get(bookId: Id): Promise<BookDetail>;
  /**
   * 列出章节。
   * @param bookId 书籍 ID
   * @returns 章节摘要数组
   */
  listChapters(bookId: Id): Promise<ChapterSummary[]>;
  /**
   * 章节级搜索。
   * @param bookId 书籍 ID
   * @param keyword 关键词
   * @returns 搜索结果数组
   */
  searchChapters(bookId: Id, keyword: string): Promise<SearchResult[]>;
  /**
   * 标记书籍损坏。
   * @param bookId 书籍 ID
   * @param reasonCode 原因码
   */
  markBroken(bookId: Id, reasonCode: string): Promise<void>;
}

/** 内容仓储契约。 */
export interface ContentRepository {
  /**
   * 取章节完整内容。
   * @param chapterId 章节 ID
   * @returns 章节内容
   */
  getChapter(chapterId: Id): Promise<ChapterContent>;
  /**
   * 取资源 URI。
   * @param assetId 资源 ID
   * @returns 沙箱相对路径或 undefined
   */
  getAssetUri(assetId: Id): Promise<string | undefined>;
  /**
   * 取封面 URI。
   * @param bookId 书籍 ID
   * @returns 沙箱相对路径或 undefined
   */
  getCoverUri(bookId: Id): Promise<string | undefined>;
}
