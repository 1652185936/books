/**
 * 章节讲解页 ViewModel（F05，LLD §6.5）。
 *
 * 负责把 `ContentRepository.getChapter` 的领域数据转为页面状态机，并承载 R-034 默认小节选取、
 * 阅读锚点保存钩子。页面（P-F05）只读 `state`/`activeSectionIndex` 等只读视图并调用本 VM 的命令方法，
 * 不直接碰 SQL（CLAUDE.md §5）。
 *
 * 页面状态（LLD §6.5「状态」列）：
 * - `loading`：getChapter 进行中（异步加载态，CLAUDE.md §5「所有异步操作必须有加载/成功/失败/取消状态」）。
 * - `ready`：章节正常，有至少一个小节，渲染讲解正文流。
 * - `empty`：`sections=[]` 的合法态（appendix/answer-key/index），走 ChapterEmptyView（R-034），非白屏。
 * - `broken`：章节不存在或内容损坏（getChapter 抛错），走「章节损坏」状态行。
 *
 * 「资源缺失」与「内容块不支持」是**块级**降级态（R-036），由具体渲染组件按 `assetUri`/`type` 局部呈现，
 * 不把整章拉入失败态；故本 VM 的顶层状态机只含上述四态，块级降级在渲染层处理。
 *
 * 阅读锚点（R-034 / FR-F05-04）：切换小节前调用 `saveAnchor` 钩子持久化 last_section_id；
 * 第一版进度模块（F-progress）未落地，故以可注入的 `AnchorPort` 端口承载，缺省实现为 no-op（留 TODO）。
 *
 * 未编译验证（缺 HarmonyOS SDK）：本 VM 为纯逻辑（不依赖 ArkUI 装饰器之外的 SDK），状态机/默认小节选取
 * 已用 `.ralph/f05-test/` 的 Node 端口断言。`@Observed`/`@Track` 等观测装饰器在页面侧使用。
 */
import { Id } from '../domain/entities/common';
import { ChapterContent, ContentRepository, SectionContent } from '../domain/entities/content';
import { AppError } from '../domain/entities/common';
import { AppErrors } from '../utils/AppErrors';

/** 页面顶层状态（LLD §6.5）。 */
export type LessonStatus = 'loading' | 'ready' | 'empty' | 'broken';

/**
 * 阅读锚点保存端口（FR-F05-04）。第一版进度模块未落地，由 F-progress 提供真实实现；
 * 缺省 `NoopAnchorPort` 为 no-op（不阻断 F05 主流程）。
 */
export interface AnchorPort {
  /**
   * 持久化当前阅读锚点（书内某章的最近小节/内容块）。
   * @param bookId 书籍内部主键。
   * @param chapterId 章节内部主键。
   * @param sectionId 最近小节内部主键（空 sections 章节可为 undefined）。
   * @param blockId 最近内容块内部主键（可选）。
   * @returns 持久化完成的 Promise。
   */
  saveAnchor(bookId: Id, chapterId: Id, sectionId?: Id, blockId?: Id): Promise<void>;
  /**
   * 读取该章的最近小节 ID（用于恢复，R-034 优先于默认下标 0）。
   * @param bookId 书籍内部主键。
   * @param chapterId 章节内部主键。
   * @returns 最近小节 ID；无记录返回 undefined。
   */
  loadLastSectionId(bookId: Id, chapterId: Id): Promise<Id | undefined>;
}

/**
 * 阅读锚点端口的缺省空实现（F-progress 落地前的占位，留 TODO 接线真实 ProgressRepository）。
 */
export class NoopAnchorPort implements AnchorPort {
  /**
   * 占位：不持久化（F-progress 落地后替换为 ProgressRepository.saveAnchor）。
   * @param bookId 书籍内部主键。
   * @param chapterId 章节内部主键。
   * @param sectionId 最近小节内部主键。
   * @param blockId 最近内容块内部主键。
   * @returns 立即完成的 Promise。
   */
  saveAnchor(bookId: Id, chapterId: Id, sectionId?: Id, blockId?: Id): Promise<void> {
    // TODO(F-progress)：接 ProgressRepository.saveAnchor（reading_progress.last_section_id/last_block_id）
    return Promise.resolve();
  }

  /**
   * 占位：无最近小节记录（F-progress 落地后替换为读 reading_progress.last_section_id）。
   * @param bookId 书籍内部主键。
   * @param chapterId 章节内部主键。
   * @returns 立即返回 undefined 的 Promise。
   */
  loadLastSectionId(bookId: Id, chapterId: Id): Promise<Id | undefined> {
    // TODO(F-progress)：接 ProgressRepository.getChapterProgress().lastSectionId
    return Promise.resolve(undefined);
  }
}

/**
 * 默认小节选取（R-034）：纯函数，便于单测。
 *
 * 规则（优先级自上而下）：
 * 1. 路由 `?section` 显式指定且属于本章 → 用该小节下标；
 * 2. 否则 `reading_progress.last_section_id` 有效且属于本章 → 恢复到该小节；
 * 3. 否则默认进入 `sections` 下标 0；
 * 4. 空 sections → 返回 -1（由调用方走 empty 态）。
 *
 * @param sections 章节小节数组（按 order 升序）。
 * @param requestedSectionId 路由 `?section` 指定的小节 ID（可选）。
 * @param lastSectionId 最近阅读小节 ID（可选，来自 AnchorPort）。
 * @returns 命中的小节下标；空 sections 返回 -1。
 */
export function resolveDefaultSectionIndex(
  sections: SectionContent[], requestedSectionId?: Id, lastSectionId?: Id): number {
  // 空 sections：无可进入小节（R-034 空章节走 empty 态）
  if (sections.length === 0) {
    return -1;
  }
  // 1) 路由显式 section 优先
  if (requestedSectionId !== undefined && requestedSectionId.length > 0) {
    // 显式指定小节的下标
    const requestedIdx: number = indexOfSection(sections, requestedSectionId);
    if (requestedIdx >= 0) {
      return requestedIdx;
    }
  }
  // 2) 最近阅读小节恢复（FR-F05-04）
  if (lastSectionId !== undefined && lastSectionId.length > 0) {
    // 最近小节下标
    const lastIdx: number = indexOfSection(sections, lastSectionId);
    if (lastIdx >= 0) {
      return lastIdx;
    }
  }
  // 3) 默认下标 0
  return 0;
}

/**
 * 在小节数组中按 ID 查下标。
 * @param sections 小节数组。
 * @param sectionId 目标小节 ID。
 * @returns 命中下标；未命中 -1。
 */
function indexOfSection(sections: SectionContent[], sectionId: Id): number {
  for (let i: number = 0; i < sections.length; i++) {
    if (sections[i].id === sectionId) {
      return i;
    }
  }
  return -1;
}

/**
 * 章节讲解页 ViewModel。`@Observed` 使其字段变更驱动页面刷新（页面以 `@ObjectLink` 持有）。
 */
@Observed
export class LessonVM {
  /** 内容仓储（构造注入；页面不直接持有，经 VM 间接访问，CLAUDE.md §5）。 */
  private readonly repo: ContentRepository;
  /** 阅读锚点端口（构造注入，缺省 NoopAnchorPort）。 */
  private readonly anchorPort: AnchorPort;
  /** 当前书籍 ID。 */
  private readonly bookId: Id;

  /** 顶层页面状态。 */
  status: LessonStatus = 'loading';
  /** 已加载的章节内容（status='ready'/'empty' 时有值）。 */
  chapter?: ChapterContent;
  /** 当前激活小节下标（status='ready' 时为有效下标；'empty' 时为 -1）。 */
  activeSectionIndex: number = -1;
  /** 失败错误（status='broken' 时有值，供状态行取资源键文案）。 */
  error?: AppError;

  /**
   * @param repo 内容仓储。
   * @param bookId 当前书籍内部主键。
   * @param anchorPort 阅读锚点端口（可选，缺省 NoopAnchorPort）。
   */
  constructor(repo: ContentRepository, bookId: Id, anchorPort?: AnchorPort) {
    this.repo = repo;
    this.bookId = bookId;
    this.anchorPort = anchorPort !== undefined ? anchorPort : new NoopAnchorPort();
  }

  /**
   * 加载章节内容并落定初始状态与默认小节（R-034）。失败置 'broken' 态。
   * @param chapterId 章节内部主键。
   * @param requestedSectionId 路由 `?section` 指定的小节 ID（可选）。
   * @returns 加载完成的 Promise（状态机已落定，不抛出）。
   */
  async load(chapterId: Id, requestedSectionId?: Id): Promise<void> {
    this.status = 'loading';
    this.error = undefined;
    try {
      // 章节完整内容
      const content: ChapterContent = await this.repo.getChapter(chapterId);
      this.chapter = content;
      // 空 sections → empty 态（合法，走 ChapterEmptyView，R-034）
      if (content.sections.length === 0) {
        this.status = 'empty';
        this.activeSectionIndex = -1;
        return;
      }
      // 最近阅读小节（R-034 恢复优先于默认下标 0）
      const lastSectionId: Id | undefined =
        await this.anchorPort.loadLastSectionId(this.bookId, chapterId);
      // 默认小节下标
      this.activeSectionIndex =
        resolveDefaultSectionIndex(content.sections, requestedSectionId, lastSectionId);
      this.status = 'ready';
    } catch (cause) {
      // 章节不存在/损坏 → broken 态（区别于空 sections 的 empty 态，LLD §6.5）
      this.error = AppErrors.from(cause, 'DB_QUERY_FAILED');
      this.chapter = undefined;
      this.activeSectionIndex = -1;
      this.status = 'broken';
    }
  }

  /**
   * 切换激活小节（标签切换/目录跳转）。切换前保存阅读锚点（R-034「切换前保存阅读锚点」）。
   * 越界下标静默忽略（守卫）。
   * @param index 目标小节下标。
   * @returns 切换完成的 Promise。
   */
  async switchSection(index: number): Promise<void> {
    // 仅在 ready 态且下标有效时切换
    if (this.status !== 'ready' || this.chapter === undefined) {
      return;
    }
    if (index < 0 || index >= this.chapter.sections.length || index === this.activeSectionIndex) {
      return;
    }
    // 切换前保存当前（旧）小节为阅读锚点（FR-F05-04）
    await this.persistCurrentAnchor();
    this.activeSectionIndex = index;
  }

  /**
   * 持久化当前激活小节为阅读锚点（页面退出/切章前调用，钩子端口）。
   * @returns 保存完成的 Promise。
   */
  async persistCurrentAnchor(): Promise<void> {
    // 无章节或无有效小节（空章节）时仅落章节级锚点（sectionId 省略，R-034 允许空）
    if (this.chapter === undefined) {
      return;
    }
    // 当前小节 ID（有效下标时取，否则 undefined）
    const sectionId: Id | undefined =
      this.activeSectionIndex >= 0 && this.activeSectionIndex < this.chapter.sections.length
        ? this.chapter.sections[this.activeSectionIndex].id : undefined;
    await this.anchorPort.saveAnchor(this.bookId, this.chapter.chapter.id, sectionId);
  }

  /**
   * 取当前激活小节内容（status='ready' 时有值）。
   * @returns 当前小节或 undefined。
   */
  currentSection(): SectionContent | undefined {
    if (this.chapter === undefined
      || this.activeSectionIndex < 0
      || this.activeSectionIndex >= this.chapter.sections.length) {
      return undefined;
    }
    return this.chapter.sections[this.activeSectionIndex];
  }
}
