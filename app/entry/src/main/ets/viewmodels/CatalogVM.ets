/**
 * 书籍目录页 ViewModel（F04，LLD §6.4）。
 *
 * 负责把 `BooksRepository.get`（书籍详情，判「书籍更新中」态）与 `BooksRepository.listChapters`（章节列表，
 * 含进度聚合）编排为页面状态机，并承载 `ChapterSearch`（searchChapters）与「选中预览」逻辑。页面（P-F04）
 * 只读本 VM 的只读视图字段并调用其命令方法，不直接执行 SQL（CLAUDE.md §5）。
 *
 * 页面状态（LLD §6.4「状态」列）：
 * - `loading`：首次加载（get + listChapters）进行中（异步加载态，CLAUDE.md §5）。
 * - `normal`：书籍 ready/broken 且章节列表正常渲染（含搜索有结果）。
 * - `no-match`：已发起搜索（关键字去空白后非空）但 searchChapters 返回空（LLD §6.4「无匹配」）。
 * - `chapter-broken`：存在内容损坏章节（ContentRepository.getChapter 失败判定），整页加「章节损坏」提示但不阻断其余章节。
 * - `book-updating`：书籍 `status='updating'`（LLD §6.4「书籍更新中」）。
 * - `error`：get/listChapters 失败（结构性错误，走通用错误态 + 重试）。
 *
 * 「章节损坏」判定：以**只读**调用 `ContentRepository.getChapter(chapterId)` 是否抛错判定，
 * 不修改 ContentRepository（其 F05 临时 listChapters 暂保留，本 VM 用 BooksRepository.listChapters 取正式契约数据）。
 *
 * 取消语义：HarmonyOS Promise 无原生 abort，搜索以「世代号」丢弃过期回包（输入抖动时旧请求不覆盖新结果）。
 *
 * 未编译验证（缺 HarmonyOS SDK）：本 VM 为纯逻辑（不依赖 ArkUI 装饰器之外的 SDK）；
 * BooksRepository.listChapters/searchChapters 的 SQL 口径已用 `.ralph/f04-test/` 真 SQLite 回归。
 */
import { Id } from '../domain/entities/common';
import { BookDetail, ChapterSummary, SearchResult } from '../domain/entities/content';
import { BooksRepository } from '../repositories/BooksRepository';
import { ContentRepository } from '../domain/entities/content';
import { AppError } from '../domain/entities/common';
import { AppErrors, DB_QUERY_FAILED } from '../utils/AppErrors';

/** 页面顶层状态机（LLD §6.4 状态列 + 通用加载/错误）。 */
export type CatalogStatus =
  | 'loading'
  | 'normal'
  | 'no-match'
  | 'chapter-broken'
  | 'book-updating'
  | 'error';

/**
 * 书籍目录页 ViewModel。`@Observed` 使其字段变更驱动页面刷新（页面以 `@State` 镜像快照或 `@ObjectLink` 持有）。
 */
@Observed
export class CatalogVM {
  /** 书籍仓储（构造注入；提供 get / listChapters / searchChapters，页面不直接执行 SQL）。 */
  private readonly booksRepo: BooksRepository;
  /** 内容仓储（构造注入；仅**只读**调用 getChapter 判定章节损坏，不修改其实现）。 */
  private readonly contentRepo: ContentRepository;
  /** 当前书籍内部主键。 */
  private readonly bookId: Id;
  /** 搜索世代号：每次搜索自增，过期回包据此丢弃（逻辑取消）。 */
  private searchGeneration: number = 0;

  /** 顶层页面状态。 */
  status: CatalogStatus = 'loading';
  /** 书籍详情（加载成功后有值，供 ChapterPreview/标题展示）。 */
  book?: BookDetail;
  /** 全量章节列表（按 order_no 升序，listChapters 结果）。 */
  chapters: ChapterSummary[] = [];
  /** 当前搜索关键字（去空白后非空才视为已发起搜索）。 */
  keyword: string = '';
  /** 当前搜索结果（已发起搜索时有值；未搜索时为空数组）。 */
  searchResults: SearchResult[] = [];
  /** 内容损坏的章节 ID 集合（chapter-broken 态下高亮提示；不阻断其余章节）。 */
  brokenChapterIds: Set<Id> = new Set<Id>();
  /** 选中预览的章节 ID（ChapterPreview 用；未选中为 undefined）。 */
  selectedChapterId?: Id;
  /** 失败错误（status='error' 时有值，供状态行取资源键文案）。 */
  error?: AppError;

  /**
   * 构造目录页 ViewModel。
   * @param booksRepo 书籍仓储（已就绪，提供 F04 listChapters/searchChapters）。
   * @param contentRepo 内容仓储（已就绪，仅只读用于章节损坏判定）。
   * @param bookId 当前书籍内部主键。
   */
  constructor(booksRepo: BooksRepository, contentRepo: ContentRepository, bookId: Id) {
    this.booksRepo = booksRepo;
    this.contentRepo = contentRepo;
    this.bookId = bookId;
  }

  /**
   * 首次加载：取书籍详情 + 章节列表，落定初始状态机（书籍更新中 / 章节损坏 / 正常 / 错误）。
   * 失败置 'error' 态（结构性错误，可重试）；不抛出（状态机内部落定）。
   * @returns 加载完成的 Promise。
   */
  async load(): Promise<void> {
    this.status = 'loading';
    this.error = undefined;
    try {
      // 书籍详情（不存在/已删除会抛错 → error 态）
      const book: BookDetail = await this.booksRepo.get(this.bookId);
      this.book = book;
      // 全量章节列表（含进度聚合，按 order_no 升序）
      const chapters: ChapterSummary[] = await this.booksRepo.listChapters(this.bookId);
      this.chapters = chapters;
      // 默认选中首章（供预览区初始展示；无章节时不选）
      this.selectedChapterId = chapters.length > 0 ? chapters[0].id : undefined;
      // 探测内容损坏章节（只读 getChapter，不修改 ContentRepository）
      this.brokenChapterIds = await this.detectBrokenChapters(chapters);
      // 落定顶层状态：书籍更新中优先 > 章节损坏 > 正常
      this.status = this.resolveBaseStatus();
    } catch (cause) {
      // 结构性失败（书籍不存在/查询失败）：归一为领域错误并落 error 态
      this.error = AppErrors.from(cause, DB_QUERY_FAILED);
      this.book = undefined;
      this.chapters = [];
      this.selectedChapterId = undefined;
      this.status = 'error';
    }
  }

  /**
   * 设置搜索关键字并执行章节级搜索（ChapterSearch 输入驱动）。
   *
   * 去空白后为空 → 清空搜索、回落到加载完成时的基础状态（正常 / 章节损坏 / 书籍更新中），不进入「无匹配」。
   * 去空白后非空 → 调 `searchChapters`：有结果落 'normal'，无结果落 'no-match'（LLD §6.4）。
   * 以世代号丢弃过期回包（输入抖动时旧请求不覆盖新结果）。
   * @param keyword 新关键字（可含首尾空白，内部去空白）。
   * @returns 搜索完成的 Promise。
   */
  async setKeyword(keyword: string): Promise<void> {
    this.keyword = keyword;
    // 去空白后的关键字（空则视为未搜索）
    const trimmed: string = keyword.trim();
    // 本次搜索世代号（回包时据此判断是否被更新请求取代）
    const generation: number = ++this.searchGeneration;
    if (trimmed.length === 0) {
      // 清空搜索：回落到基础状态（不进入无匹配态）
      this.searchResults = [];
      this.status = this.resolveBaseStatus();
      return;
    }
    try {
      // 章节级搜索结果（命中 title/titleZh）
      const results: SearchResult[] = await this.booksRepo.searchChapters(this.bookId, trimmed);
      if (generation !== this.searchGeneration) {
        // 已有更新的搜索请求发出，丢弃本次过期回包（逻辑取消）
        return;
      }
      this.searchResults = results;
      // 书籍更新中态优先于搜索结果展示（仍允许检索但顶层提示更新中）
      if (this.book !== undefined && this.book.status === 'updating') {
        this.status = 'book-updating';
        return;
      }
      // 有结果落正常态；无结果落无匹配态（LLD §6.4）
      this.status = results.length > 0 ? 'normal' : 'no-match';
    } catch (cause) {
      if (generation !== this.searchGeneration) {
        // 过期回包的异常同样丢弃，不污染当前状态
        return;
      }
      // 搜索查询失败：落 error 态（可重试）
      this.error = AppErrors.from(cause, DB_QUERY_FAILED);
      this.status = 'error';
    }
  }

  /**
   * 选中章节预览（ChapterList 点击驱动 ChapterPreview 展示）。越界/不存在的 ID 静默忽略（守卫）。
   * @param chapterId 目标章节内部主键。
   */
  selectChapter(chapterId: Id): void {
    // 仅选中确实存在的章节（防止预览区取空）
    if (this.chapters.some((c: ChapterSummary): boolean => c.id === chapterId)) {
      this.selectedChapterId = chapterId;
    }
  }

  /**
   * 重试（error 态下「重试」按钮触发）：重新执行首次加载。
   * @returns 加载完成的 Promise。
   */
  async retry(): Promise<void> {
    await this.load();
  }

  /**
   * 取当前选中章节摘要（ChapterPreview 用）。
   * @returns 选中章节摘要；未选中或不存在时为 undefined。
   */
  selectedChapter(): ChapterSummary | undefined {
    if (this.selectedChapterId === undefined) {
      return undefined;
    }
    // 在全量章节中查选中章
    return this.chapters.find((c: ChapterSummary): boolean => c.id === this.selectedChapterId);
  }

  /**
   * 当前是否处于「已发起搜索」态（关键字去空白后非空）。供页面决定渲染全量列表还是搜索结果。
   * @returns 已发起搜索时为 true。
   */
  isSearching(): boolean {
    return this.keyword.trim().length > 0;
  }

  /**
   * 某章节是否内容损坏（ChapterList 据此置损坏徽标、禁用「开始学习」）。
   * @param chapterId 章节内部主键。
   * @returns 损坏时为 true。
   */
  isChapterBroken(chapterId: Id): boolean {
    return this.brokenChapterIds.has(chapterId);
  }

  /**
   * 计算加载完成后的基础顶层状态（不含搜索维度）：书籍更新中 > 章节损坏 > 正常。
   * @returns 基础状态。
   */
  private resolveBaseStatus(): CatalogStatus {
    // 书籍更新中优先（LLD §6.4「书籍更新中」覆盖态）
    if (this.book !== undefined && this.book.status === 'updating') {
      return 'book-updating';
    }
    // 存在内容损坏章节：整页加「章节损坏」提示（不阻断其余章节渲染）
    if (this.brokenChapterIds.size > 0) {
      return 'chapter-broken';
    }
    return 'normal';
  }

  /**
   * 探测内容损坏章节：对每章只读调用 `ContentRepository.getChapter`，抛错即视为该章内容损坏。
   * 不修改 ContentRepository；空 sections（appendix/answer-key/index）是合法态、不计入损坏（getChapter 不抛错）。
   * @param chapters 全量章节列表。
   * @returns 损坏章节 ID 集合。
   */
  private async detectBrokenChapters(chapters: ChapterSummary[]): Promise<Set<Id>> {
    // 损坏章节 ID 集合
    const broken: Set<Id> = new Set<Id>();
    for (const chapter of chapters) {
      try {
        // 只读探测：getChapter 成功即章节内容可解析（含空 sections 合法态）
        await this.contentRepo.getChapter(chapter.id);
      } catch (cause) {
        // 章节不存在/内容损坏（DB_QUERY_FAILED 等）：计入损坏集合，不阻断后续章节探测
        void AppErrors.from(cause, DB_QUERY_FAILED);
        broken.add(chapter.id);
      }
    }
    return broken;
  }
}
