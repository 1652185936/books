import { common } from '@kit.AbilityKit';
import { CatalogParams, LessonParams, RouteName } from '../../utils/Routes';
import { Database } from '../../database/Database';
import { BooksRepository } from '../../repositories/BooksRepository';
import { ContentRepositoryImpl } from '../../repositories/ContentRepository';
import { CatalogVM, CatalogStatus } from '../../viewmodels/CatalogVM';
import { BookDetail, ChapterSummary, SearchResult } from '../../domain/entities/content';
import { Id } from '../../domain/entities/common';
import { AppErrors } from '../../utils/AppErrors';
import { ChapterList } from '../../components/catalog/ChapterList';
import { ChapterSearch } from '../../components/catalog/ChapterSearch';
import { ChapterPreview } from '../../components/catalog/ChapterPreview';
import { LessonTokens } from '../../components/lesson/LessonTokens';

/** 左栏宽度（vp）：LLD §6.4 约束 280..360vp，取区间内 320vp。 */
const LEFT_COLUMN_WIDTH: number = 320;

/**
 * P-F04 书籍目录页路由构建函数（route_map.json → `book`，LLD §6.4）。
 * 参数 `bookId`（CatalogParams）在 NavDestination.onReady 经 `ctx.pathInfo.param` 解析。
 * @returns 无（构建 NavDestination）。
 */
@Builder
export function CatalogPageBuilder(): void {
  CatalogPage();
}

/**
 * P-F04 书籍目录页（路由 `book/{bookId}`，LLD §6.4）。
 *
 * 主组件：ChapterSearch（章节搜索）+ ChapterList（左栏 280..360vp 章节列表，含完成度/进度徽标）
 * + ChapterPreview（右侧选中预览 + 「开始学习」跳转 P-F05）。状态机由 CatalogVM 承载
 * （正常 / 无匹配 / 章节损坏 / 书籍更新中 / 加载 / 错误，LLD §6.4 状态列）。
 * 目录滚动位置按 bookId 保存（页面内 `scrollOffsetByBook` 维护，LLD §6.4 页面约束）。
 * 页面把 VM 的状态/数据快照镜像进 `@State` 以稳定触发异步态重渲染。
 *
 * 「开始学习」经 `ctx.pathStack.pushPathByName(RouteName.LESSON, { bookId, chapterId })` 跳转；
 * 页面不直接执行 SQL（CLAUDE.md §5），取数经 BooksRepository（章节列表/搜索）+ ContentRepository（只读损坏探测）。
 *
 * 未编译验证（缺 HarmonyOS SDK）：ArkUI 组件/装饰器与 relationalStore/NavPathStack API 以 API 12 为准，真机待实测。
 */
@Component
export struct CatalogPage {
  /** 页面状态快照（镜像 VM.status，驱动主体分发）。 */
  @State status: CatalogStatus = 'loading';
  /** 书籍详情快照（镜像 VM.book，标题展示用）。 */
  @State book?: BookDetail = undefined;
  /** 当前左栏渲染的章节列表（全量或搜索命中映射后的章节）。 */
  @State displayChapters: ChapterSummary[] = [];
  /** 损坏章节 ID 集合快照（镜像 VM.brokenChapterIds）。 */
  @State brokenChapterIds: Set<Id> = new Set<Id>();
  /** 当前选中章节 ID 快照（镜像 VM.selectedChapterId）。 */
  @State selectedChapterId: string = '';
  /** 当前关键字快照（镜像 VM.keyword）。 */
  @State keyword: string = '';
  /** 当前书籍的目录滚动偏移（恢复点；按 bookId 保存于 scrollOffsetByBook）。 */
  @State currentScrollOffset: number = 0;
  /** 导航栈（onReady 取 ctx.pathStack；「开始学习」跳转 P-F05 用）。 */
  private pathStack?: NavPathStack = undefined;
  /** 当前书籍 ID（onReady 解析）。 */
  private bookId: Id = '';
  /** 目录页 ViewModel（逻辑/状态持有者；页面经 syncFromVm 同步快照）。 */
  private vm?: CatalogVM = undefined;
  /** 目录滚动位置按 bookId 保存（LLD §6.4 页面约束；页面内 state 即可）。 */
  private scrollOffsetByBook: Map<string, number> = new Map<string, number>();

  /**
   * 初始化仓储与首屏加载（NavDestination.onReady 调用）。
   * @param params 路由参数（bookId）。
   * @param pathStack 当前导航栈（用于「开始学习」跳转）。
   * @returns 初始化完成的 Promise。
   */
  private async init(params: CatalogParams, pathStack: NavPathStack): Promise<void> {
    this.bookId = params.bookId;
    this.pathStack = pathStack;
    // 恢复该书上次目录滚动位置（无则 0）
    this.currentScrollOffset = this.scrollOffsetByBook.get(this.bookId) ?? 0;
    try {
      // 应用上下文（提供沙箱目录与 rawfile 资源）
      const context: common.Context = getContext(this) as common.Context;
      // 已完成迁移、就绪的数据库封装
      const database: Database = await Database.open(context);
      // 书籍仓储（list/get/listChapters/searchChapters）+ 内容仓储（只读损坏探测）
      const booksRepo: BooksRepository = new BooksRepository(database);
      const contentRepo: ContentRepositoryImpl = new ContentRepositoryImpl(database);
      // 构建 VM 并加载
      const vm: CatalogVM = new CatalogVM(booksRepo, contentRepo, this.bookId);
      this.vm = vm;
      await vm.load();
      this.syncFromVm();
    } catch (cause) {
      // 库打开/构造失败：归一为领域错误并落错误态（不输出敏感路径，CLAUDE.md §5）
      void AppErrors.from(cause, 'DB_QUERY_FAILED');
      this.status = 'error';
    }
  }

  /**
   * 把 VM 的状态/数据快照同步进页面 `@State`（保证异步态变更稳定触发重渲染）。
   */
  private syncFromVm(): void {
    // VM 未就绪时维持加载态
    if (this.vm === undefined) {
      this.status = 'loading';
      return;
    }
    this.status = this.vm.status;
    this.book = this.vm.book;
    this.brokenChapterIds = this.vm.brokenChapterIds;
    this.selectedChapterId = this.vm.selectedChapterId !== undefined ? this.vm.selectedChapterId : '';
    this.keyword = this.vm.keyword;
    this.displayChapters = this.resolveDisplayChapters();
  }

  /**
   * 计算左栏渲染章节：搜索态用搜索结果映射回章节（保序），否则全量章节。
   * @returns 待渲染章节列表。
   */
  private resolveDisplayChapters(): ChapterSummary[] {
    if (this.vm === undefined) {
      return [];
    }
    // 非搜索态：全量章节
    if (!this.vm.isSearching()) {
      return this.vm.chapters;
    }
    // 搜索态：按搜索结果顺序映射回章节摘要（搜索结果已按 order_no 升序）
    const byId: Map<string, ChapterSummary> = new Map<string, ChapterSummary>();
    for (const chapter of this.vm.chapters) {
      byId.set(chapter.id, chapter);
    }
    // 命中章节列表（保持搜索结果顺序，过滤映射不到的脏项）
    const hits: ChapterSummary[] = [];
    for (const result of this.vm.searchResults) {
      // 命中章节摘要
      const chapter: ChapterSummary | undefined = byId.get(result.chapterId);
      if (chapter !== undefined) {
        hits.push(chapter);
      }
    }
    return hits;
  }

  /**
   * 选中章节预览（ChapterList 点击）。委托 VM，再同步快照。
   * @param chapterId 目标章节 ID。
   */
  private onSelectChapter(chapterId: Id): void {
    if (this.vm === undefined) {
      return;
    }
    this.vm.selectChapter(chapterId);
    this.selectedChapterId = this.vm.selectedChapterId !== undefined ? this.vm.selectedChapterId : '';
  }

  /**
   * 关键字变化（ChapterSearch 输入）。委托 VM 搜索，再同步快照。
   * @param keyword 新关键字。
   * @returns 搜索完成的 Promise。
   */
  private async onKeywordChange(keyword: string): Promise<void> {
    if (this.vm === undefined) {
      return;
    }
    await this.vm.setKeyword(keyword);
    this.syncFromVm();
  }

  /**
   * 保存当前书目录滚动位置（按 bookId）。
   * @param offsetY 当前纵向滚动偏移。
   */
  private onScrollOffsetChange(offsetY: number): void {
    this.currentScrollOffset = offsetY;
    this.scrollOffsetByBook.set(this.bookId, offsetY);
  }

  /**
   * 开始学习：跳转 P-F05 章节讲解页（携带 bookId/chapterId）。
   * @param chapterId 目标章节 ID。
   */
  private onStartLearning(chapterId: Id): void {
    if (this.pathStack === undefined) {
      return;
    }
    // 章节讲解页参数（LessonParams）
    const params: LessonParams = { bookId: this.bookId, chapterId: chapterId };
    this.pathStack.pushPathByName(RouteName.LESSON, params);
  }

  /**
   * 重试（error 态）：重新加载并同步快照。
   * @returns 重试完成的 Promise。
   */
  private async onRetry(): Promise<void> {
    if (this.vm === undefined) {
      return;
    }
    await this.vm.retry();
    this.syncFromVm();
  }

  /**
   * 当前选中章节摘要（预览区用）。
   * @returns 选中章节或 undefined。
   */
  private currentSelected(): ChapterSummary | undefined {
    if (this.vm === undefined) {
      return undefined;
    }
    return this.vm.selectedChapter();
  }

  /**
   * 状态行占位（居中文案，加载/无匹配/错误等共用）。
   * @param text 文案资源。
   * @param color 文案颜色。
   */
  @Builder
  statusLine(text: ResourceStr, color: string) {
    Column() {
      Text(text)
        .fontSize(LessonTokens.FONT_BODY)
        .fontColor(color)
    }
    .layoutWeight(1)
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 顶部状态横幅（章节损坏 / 书籍更新中提示，覆盖在列表上方，不阻断浏览）。
   * @param text 文案资源。
   */
  @Builder
  banner(text: ResourceStr) {
    Row() {
      Text(text)
        .fontSize(LessonTokens.FONT_CAPTION)
        .fontColor(LessonTokens.WARN_AMBER)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor(LessonTokens.SURFACE)
  }

  /**
   * 左栏：搜索框 + 状态横幅 + 章节列表（或无匹配占位）。
   */
  @Builder
  leftColumn() {
    Column() {
      // 搜索框
      ChapterSearch({
        keyword: this.keyword,
        onKeywordChange: (keyword: string): void => {
          this.onKeywordChange(keyword);
        }
      })
      // 状态横幅（书籍更新中 / 章节损坏）
      if (this.status === 'book-updating') {
        this.banner($r('app.string.catalog_book_updating'))
      } else if (this.status === 'chapter-broken') {
        this.banner($r('app.string.catalog_chapter_broken_hint'))
      }
      // 列表区：无匹配占位 / 章节列表
      if (this.status === 'no-match') {
        this.statusLine($r('app.string.catalog_no_match'), LessonTokens.INK_MUTED)
      } else {
        ChapterList({
          chapters: this.displayChapters,
          selectedChapterId: this.selectedChapterId,
          brokenChapterIds: this.brokenChapterIds,
          initialScrollOffset: this.currentScrollOffset,
          onSelectChapter: (chapterId: Id): void => {
            this.onSelectChapter(chapterId);
          },
          onScrollOffsetChange: (offsetY: number): void => {
            this.onScrollOffsetChange(offsetY);
          }
        })
          .layoutWeight(1)
      }
    }
    .width(LEFT_COLUMN_WIDTH)
    .height('100%')
    .backgroundColor(Color.White)
    .border({ width: { right: 1 }, color: LessonTokens.BORDER })
  }

  /**
   * 主体内容区按页面状态分发（加载 / 错误 / 双栏目录）。
   */
  @Builder
  body() {
    if (this.status === 'loading') {
      // 加载态
      this.statusLine($r('app.string.state_loading'), LessonTokens.INK_SECONDARY)
    } else if (this.status === 'error') {
      // 结构性错误态 + 重试
      Column({ space: 12 }) {
        Text($r('app.string.state_error'))
          .fontSize(LessonTokens.FONT_BODY)
          .fontColor(LessonTokens.INK_SECONDARY)
        Button($r('app.string.action_retry'))
          .type(ButtonType.Capsule)
          .height(LessonTokens.TOUCH_MIN)
          .backgroundColor(LessonTokens.BRAND_RED)
          .fontColor(Color.White)
          .onClick(() => {
            this.onRetry();
          })
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else {
      // 正常 / 无匹配 / 章节损坏 / 书籍更新中：双栏（左目录 + 右预览）
      Row() {
        this.leftColumn()
        // 右侧预览区
        Column() {
          ChapterPreview({
            chapter: this.currentSelected(),
            broken: this.selectedChapterId.length > 0 && this.brokenChapterIds.has(this.selectedChapterId),
            onStartLearning: (chapterId: Id): void => {
              this.onStartLearning(chapterId);
            }
          })
        }
        .layoutWeight(1)
        .height('100%')
      }
      .width('100%')
      .height('100%')
    }
  }

  build() {
    NavDestination() {
      Column() {
        this.body()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.White)
    }
    .title($r('app.string.route_title_catalog'))
    .onReady((ctx: NavDestinationContext) => {
      // 解析路由参数（CatalogParams）并初始化（pathStack 用于「开始学习」跳转）
      const params: CatalogParams = ctx.pathInfo.param as CatalogParams;
      this.init(params, ctx.pathStack);
    })
  }
}
