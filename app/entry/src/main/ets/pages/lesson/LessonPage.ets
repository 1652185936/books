import { common } from '@kit.AbilityKit';
import { LessonParams } from '../../utils/Routes';
import { Database } from '../../database/Database';
import { ContentRepositoryImpl } from '../../repositories/ContentRepository';
import { LessonVM, LessonStatus } from '../../viewmodels/LessonVM';
import { ChapterSummary, ContentBlock, SectionContent } from '../../domain/entities/content';
import { Id } from '../../domain/entities/common';
import { LessonHeader } from '../../components/lesson/LessonHeader';
import { LessonTabs } from '../../components/lesson/LessonTabs';
import { ChapterDrawer } from '../../components/lesson/ChapterDrawer';
import { ChapterEmptyView } from '../../components/lesson/ChapterEmptyView';
import { ContentBlockRenderer } from '../../components/lesson/ContentBlockRenderer';
import { LessonTokens } from '../../components/lesson/LessonTokens';

/**
 * P-F05 章节讲解页路由构建函数（route_map.json → `lesson`，LLD §6.5）。
 * 参数 `bookId/chapterId/section?`（LessonParams）在 onReady 经 `ctx.pathInfo.param` 解析。
 * @returns 无（构建 NavDestination）。
 */
@Builder
export function LessonPageBuilder(): void {
  LessonPage();
}

/**
 * P-F05 章节讲解页（路由 `lesson/{bookId}/{chapterId}?section={sectionId}`，LLD §6.5）。
 *
 * 主组件：LessonHeader（标题 + 换章按钮 + 收藏）、LessonTabs（小节标签）、ContentBlockRenderer（11 种块分发）、
 * ChapterDrawer（目录抽屉换章）、ChapterEmptyView（空 sections）。换章只走「上一章/下一章按钮 + 目录抽屉」，
 * **禁止左右滑动换章**（CLAUDE.md §2.6）。状态机由 LessonVM 承载；页面把 VM 的状态/数据快照进页面 `@State`
 * 以确保异步态变更稳定触发重渲染（不依赖 `@Observed` 深层观测的版本差异）。
 *
 * 未编译验证（缺 HarmonyOS SDK）：ArkUI 组件/装饰器与 relationalStore API 形态以 API 12 为准，真机待实测。
 */
@Component
export struct LessonPage {
  /** 页面状态快照（镜像 VM.status，驱动主体分发）。 */
  @State status: LessonStatus = 'loading';
  /** 当前章节摘要快照（镜像 VM.chapter.chapter）。 */
  @State chapterSummary?: ChapterSummary = undefined;
  /** 当前章节小节快照（镜像 VM.chapter.sections）。 */
  @State sections: SectionContent[] = [];
  /** 当前激活小节下标快照（镜像 VM.activeSectionIndex）。 */
  @State activeSectionIndex: number = -1;
  /** 全书章节列表（目录抽屉用，onReady 加载）。 */
  @State chapters: ChapterSummary[] = [];
  /** 目录抽屉是否展开。 */
  @State drawerVisible: boolean = false;
  /** illustration 块 ID → 已解析图片 URI（缺图为空串→资源缺失态）。 */
  @State imageUriByBlock: Map<string, string> = new Map<string, string>();
  /** 当前书籍 ID（onReady 解析）。 */
  private bookId: Id = '';
  /** 当前章节 ID（onReady 解析；换章后更新）。 */
  private chapterId: Id = '';
  /** 章节讲解 ViewModel（逻辑/状态持有者；页面经 syncFromVm 同步快照）。 */
  private vm?: LessonVM = undefined;
  /** 内容仓储（onReady 初始化；兼取章节列表供目录抽屉）。 */
  private contentRepo?: ContentRepositoryImpl = undefined;
  /** 应用上下文（解析沙箱图片 URI 用）。 */
  private appContext?: common.UIAbilityContext = undefined;

  /**
   * 初始化仓储与首章加载（NavDestination.onReady 调用）。
   * @param params 路由参数（bookId/chapterId/section?）。
   * @returns 初始化完成的 Promise。
   */
  private async init(params: LessonParams): Promise<void> {
    this.bookId = params.bookId;
    this.chapterId = params.chapterId;
    // 应用上下文（沙箱目录用于拼图片 file:// URI）
    this.appContext = getContext(this) as common.UIAbilityContext;
    // 打开数据库并构建仓储（页面不直接执行 SQL，经仓储，CLAUDE.md §5）
    const database: Database = await Database.open(this.appContext);
    const repo: ContentRepositoryImpl = new ContentRepositoryImpl(database);
    this.contentRepo = repo;
    // 章节列表（目录抽屉换章用）
    this.chapters = await repo.listChapters(this.bookId);
    // 构建 VM 并加载首章
    const vm: LessonVM = new LessonVM(repo, this.bookId);
    this.vm = vm;
    await vm.load(this.chapterId, params.section);
    this.syncFromVm();
    await this.resolveImages();
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
    this.chapterSummary = this.vm.chapter !== undefined ? this.vm.chapter.chapter : undefined;
    this.sections = this.vm.chapter !== undefined ? this.vm.chapter.sections : [];
    this.activeSectionIndex = this.vm.activeSectionIndex;
  }

  /**
   * 解析当前章节内全部 illustration 块的图片为可加载 URI，写入 imageUriByBlock（缺图留空串）。
   * @returns 解析完成的 Promise。
   */
  private async resolveImages(): Promise<void> {
    // 新映射（替换触发刷新）
    const map: Map<string, string> = new Map<string, string>();
    // 沙箱文件根目录（拼接资源相对路径为 file:// URI）
    const filesDir: string = this.appContext !== undefined ? this.appContext.filesDir : '';
    // 遍历各小节各块，对 illustration 解析 assetUri
    for (let i: number = 0; i < this.sections.length; i++) {
      // 当前小节块列表
      const blocks: ContentBlock[] = this.sections[i].blocks;
      for (let j: number = 0; j < blocks.length; j++) {
        // 当前块
        const block: ContentBlock = blocks[j];
        if (block.type === 'illustration' && block.assetUri !== undefined && block.assetUri.length > 0) {
          // 沙箱相对路径 → file:// 绝对 URI（仅授权/原创资源，CLAUDE.md §2.10）
          map.set(block.id, `file://${filesDir}/${block.assetUri}`);
        }
      }
    }
    this.imageUriByBlock = map;
  }

  /**
   * 取当前章在 chapters 中的下标（用于上一章/下一章可用性判定）。
   * @returns 当前章下标；未找到 -1。
   */
  private currentChapterIndex(): number {
    for (let i: number = 0; i < this.chapters.length; i++) {
      if (this.chapters[i].id === this.chapterId) {
        return i;
      }
    }
    return -1;
  }

  /**
   * 切换激活小节（标签点击）。委托 VM（切换前保存锚点，R-034），再同步快照。
   * @param index 目标小节下标。
   * @returns 切换完成的 Promise。
   */
  private async switchSection(index: number): Promise<void> {
    if (this.vm === undefined) {
      return;
    }
    await this.vm.switchSection(index);
    this.activeSectionIndex = this.vm.activeSectionIndex;
  }

  /**
   * 换章：保存当前阅读锚点 → 切换 chapterId → 重新加载（进入新章下标 0/恢复，R-034）。
   * @param chapterId 目标章节 ID。
   * @returns 换章完成的 Promise。
   */
  private async switchChapter(chapterId: Id): Promise<void> {
    this.drawerVisible = false;
    if (this.vm === undefined || chapterId === this.chapterId) {
      return;
    }
    // 换章前保存当前章锚点（R-034「切换前保存阅读锚点」）
    await this.vm.persistCurrentAnchor();
    this.chapterId = chapterId;
    // 切到加载态再加载，给出加载反馈
    this.status = 'loading';
    await this.vm.load(chapterId);
    this.syncFromVm();
    await this.resolveImages();
  }

  /**
   * 进入上一章（首章禁用）。
   */
  private goPrevChapter(): void {
    // 当前章下标
    const idx: number = this.currentChapterIndex();
    if (idx > 0) {
      this.switchChapter(this.chapters[idx - 1].id);
    }
  }

  /**
   * 进入下一章（末章禁用）。
   */
  private goNextChapter(): void {
    // 当前章下标
    const idx: number = this.currentChapterIndex();
    if (idx >= 0 && idx < this.chapters.length - 1) {
      this.switchChapter(this.chapters[idx + 1].id);
    }
  }

  /**
   * 渲染当前激活小节的内容块流（status='ready' 时）。
   * @param section 当前小节。
   */
  @Builder
  sectionContent(section: SectionContent) {
    Scroll() {
      Column({ space: LessonTokens.BLOCK_GAP }) {
        ForEach(section.blocks, (block: ContentBlock, index: number) => {
          ContentBlockRenderer({
            block: block,
            resolvedImageUri: this.imageUriByBlock.has(block.id)
              ? (this.imageUriByBlock.get(block.id) as string) : ''
          })
        }, (block: ContentBlock, index: number) => `${index}-${block.id}`)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: LessonTokens.PAGE_PADDING,
        right: LessonTokens.PAGE_PADDING,
        top: LessonTokens.PAGE_PADDING,
        bottom: 48
      })
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.TopStart)
    .scrollBar(BarState.Auto)
  }

  /**
   * 状态行占位（加载/章节损坏共用：居中文案）。
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
   * 当前激活小节（下标有效时取，否则 undefined）。
   * @returns 当前小节或 undefined。
   */
  private currentSection(): SectionContent | undefined {
    if (this.activeSectionIndex < 0 || this.activeSectionIndex >= this.sections.length) {
      return undefined;
    }
    return this.sections[this.activeSectionIndex];
  }

  /**
   * 主体内容区按页面状态分发（加载/正常/空章节/章节损坏）。
   */
  @Builder
  body() {
    if (this.status === 'loading') {
      // 加载态
      this.statusLine($r('app.string.state_loading'), LessonTokens.INK_SECONDARY)
    } else if (this.status === 'broken') {
      // 章节损坏态（区别于空 sections）
      this.statusLine($r('app.string.lesson_chapter_broken'), LessonTokens.WARN_AMBER)
    } else if (this.status === 'empty') {
      // 空 sections 章节（R-034，走 ChapterEmptyView 不白屏）
      ChapterEmptyView({ kind: this.chapterSummary !== undefined ? this.chapterSummary.kind : 'appendix' })
    } else {
      // 正常态：小节标签 + 当前小节内容流
      Column() {
        LessonTabs({
          sections: this.sections,
          activeIndex: this.activeSectionIndex,
          onSwitch: (index: number): void => {
            this.switchSection(index);
          }
        })
        if (this.currentSection() !== undefined) {
          this.sectionContent(this.currentSection() as SectionContent)
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
  }

  build() {
    NavDestination() {
      Stack() {
        Column() {
          // 头部：标题 + 换章按钮 + 收藏（禁止滑动换章）
          if (this.chapterSummary !== undefined) {
            LessonHeader({
              chapter: this.chapterSummary,
              canPrev: this.currentChapterIndex() > 0,
              canNext: this.currentChapterIndex() >= 0
                && this.currentChapterIndex() < this.chapters.length - 1,
              onOpenDrawer: (): void => {
                this.drawerVisible = true;
              },
              onPrevChapter: (): void => {
                this.goPrevChapter();
              },
              onNextChapter: (): void => {
                this.goNextChapter();
              }
            })
          }
          // 主体内容（状态分发）
          this.body()
        }
        .width('100%')
        .height('100%')
        .backgroundColor(Color.White)

        // 目录抽屉（覆盖层，换章入口之一）
        ChapterDrawer({
          visible: this.drawerVisible,
          chapters: this.chapters,
          currentChapterId: this.chapterId,
          onSelectChapter: (chapterId: Id): void => {
            this.switchChapter(chapterId);
          },
          onClose: (): void => {
            this.drawerVisible = false;
          }
        })
      }
      .width('100%')
      .height('100%')
    }
    .title($r('app.string.route_title_lesson'))
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      // 解析路由参数（LessonParams）并初始化
      const params: LessonParams = ctx.pathInfo.param as LessonParams;
      this.init(params);
    })
  }
}
