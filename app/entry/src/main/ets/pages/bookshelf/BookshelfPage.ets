import { common } from '@kit.AbilityKit';
import { Database } from '../../database/Database';
import { BooksRepository } from '../../repositories/BooksRepository';
import { BookshelfVM } from '../../viewmodels/BookshelfVM';
import { BookSummary } from '../../domain/entities/content';
import { ContinueTarget } from '../../domain/entities/content';
import { AppErrors } from '../../utils/AppErrors';
import {
  RouteName,
  CatalogParams,
  LessonParams
} from '../../utils/Routes';
import { AppRail, RailSortKey } from '../../components/bookshelf/AppRail';
import { BookGrid } from '../../components/bookshelf/BookGrid';
import { ImportToast } from '../../components/bookshelf/ImportToast';
import { BookshelfStateView } from '../../components/bookshelf/BookshelfStateView';

/** 左侧导航栏宽度（vp，平板横屏基线 1280×800，CLAUDE.md §6）。 */
const RAIL_WIDTH: number = 240;

/**
 * P-F01 书架页（Navigation 根内容，路由 `bookshelf`，LLD §6.1）。
 *
 * F01 接管：左 AppRail（排序/导入）+ 右内容区（BookGrid 书卡栅格 / 四态占位 + ImportToast）。
 * 四态：空书架（empty）、正常（content）、加载（loading）、错误（error）；其中「书籍损坏」以 content 态下
 * 卡片状态徽标 + 顶部横幅体现（LLD §6.1 状态列）。
 *
 * 数据：经 `Database.open(context)` 取就绪库并构造 `BooksRepository`，再由 `BookshelfVM` 编排取数；
 * 页面不直接执行 SQL（CLAUDE.md §5）。导航经 `@Consume('pageStack')` 取全局栈 `pushPathByName` 入栈：
 * 卡片 → `book/{bookId}`（目录）、继续学习 → `lesson`、导入 → `import/select`。
 *
 * 路由/接线需求（见返回说明）：`pages/Index.ets` 须把 `private pageStack` 改为 `@Provide('pageStack') pageStack`，
 * 否则本组件 `@Consume` 取不到栈；该改动由主 agent 在 Index.ets 接线。
 *
 * 未编译验证（缺 HarmonyOS SDK）：Database/relationalStore/NavPathStack API 以 API 12 为准。
 */
@Component
export struct BookshelfPage {
  /** 全局导航栈（由 Index.ets 经 @Provide('pageStack') 下发；本页消费用于跳转）。 */
  @Consume('pageStack') pageStack: NavPathStack;
  /** 书架 ViewModel（@State 持有，状态变更驱动重渲染）。 */
  @State vm: BookshelfVM | undefined = undefined;
  /** 仓储构造是否失败（库打开失败时进入错误态，避免空指针）。 */
  @State bootstrapFailed: boolean = false;

  /**
   * 组件即将出现：打开数据库、构造仓储与 ViewModel，并触发首次加载。
   * @returns 无返回值。
   */
  async aboutToAppear(): Promise<void> {
    try {
      // 应用上下文（提供沙箱目录与 rawfile 资源）
      const context: common.Context = getContext(this) as common.Context;
      // 已完成迁移、就绪的数据库封装
      const database: Database = await Database.open(context);
      // 书籍仓储（页面经其取数，不直接执行 SQL）
      const repo: BooksRepository = new BooksRepository(database);
      // 书架 ViewModel（注入仓储）
      const vm: BookshelfVM = new BookshelfVM(repo);
      this.vm = vm;
      await vm.load();
    } catch (cause) {
      // 库打开/构造失败：归一为领域错误并落错误态（不输出敏感路径，CLAUDE.md §5）
      void AppErrors.from(cause, 'DB_QUERY_FAILED');
      this.bootstrapFailed = true;
    }
  }

  build() {
    Row() {
      // 左侧导航栏：排序切换 + 导入入口
      Column() {
        AppRail({
          sort: this.currentSort(),
          onSortChange: (sort: RailSortKey): void => {
            this.onSortChange(sort)
          },
          onImport: (): void => {
            this.gotoImport()
          }
        })
      }
      .width(RAIL_WIDTH)
      .height('100%')

      // 右侧内容区：导入提示条 + 四态内容
      Column() {
        // 导入中提示条（本轮无导入任务源，默认隐藏；接线导入服务后由其驱动 visible）
        ImportToast({ visible: false, onView: (): void => {} })
        // 主内容区（按状态机渲染）
        Column() {
          this.contentArea()
        }
        .layoutWeight(1)
        .width('100%')
      }
      .layoutWeight(1)
      .height('100%')
      .backgroundColor('#FFFFFF')
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 主内容区构建器：按 bootstrap 与 VM 状态机渲染加载/空/错误/正常。
   * @returns 内容 UI。
   */
  @Builder
  contentArea() {
    if (this.bootstrapFailed) {
      // 库打开失败：错误态 + 重试（重试经 aboutToAppear 重新初始化不便，这里重试触发重新加载流程）
      BookshelfStateView({
        kind: 'error',
        errorText: $r('app.string.state_error'),
        onRetry: (): void => {
          this.retryBootstrap()
        }
      })
    } else if (this.vm === undefined || this.vm.state === 'loading') {
      // 初始化中或加载中：加载态
      BookshelfStateView({ kind: 'loading' })
    } else if (this.vm.state === 'empty') {
      // 空书架：引导导入
      BookshelfStateView({
        kind: 'empty',
        onImport: (): void => {
          this.gotoImport()
        }
      })
    } else if (this.vm.state === 'error') {
      // 加载失败：按 messageKey 取错误文案 + 重试
      BookshelfStateView({
        kind: 'error',
        errorText: this.errorText(),
        onRetry: (): void => {
          this.onRetry()
        }
      })
    } else {
      // 正常态：损坏横幅（如有）+ 书卡栅格
      Column() {
        if (this.vm.hasBrokenBook()) {
          Text($r('app.string.bookshelf_broken_banner'))
            .fontSize(13)
            .fontColor('#92400E')
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .backgroundColor('#FEF3C7')
        }
        BookGrid({
          books: this.vm.books,
          onOpen: (book: BookSummary): void => {
            this.gotoCatalog(book)
          },
          onContinue: (book: BookSummary): void => {
            this.gotoLesson(book)
          },
          onMore: (book: BookSummary, actionKey: string): void => {
            this.onMore(book, actionKey)
          }
        })
      }
      .width('100%')
      .height('100%')
    }
  }

  /**
   * 取当前排序（VM 未就绪时回退默认 last-opened）。
   * @returns 当前排序标识。
   */
  private currentSort(): RailSortKey {
    return this.vm !== undefined ? this.vm.sort : 'last-opened';
  }

  /**
   * 取当前错误态文案资源引用：按 `AppError.messageKey` 经 physicalKeyFor 桥接到物理资源名。
   * @returns 文案资源引用。
   */
  private errorText(): ResourceStr {
    if (this.vm !== undefined && this.vm.error !== undefined) {
      // 逻辑键 → 物理资源名（点分→下划线，AppErrors 约定）
      const physical: string = AppErrors.physicalKeyFor(this.vm.error.messageKey);
      return $r(`app.string.${physical}`);
    }
    return $r('app.string.state_error');
  }

  /**
   * 排序切换：委托 VM 刷新。
   * @param sort 目标排序。
   * @returns 无返回值。
   */
  private onSortChange(sort: RailSortKey): void {
    if (this.vm !== undefined) {
      this.vm.changeSort(sort);
    }
  }

  /**
   * 重试加载：委托 VM 以当前参数刷新。
   * @returns 无返回值。
   */
  private onRetry(): void {
    if (this.vm !== undefined) {
      this.vm.retry();
    }
  }

  /**
   * 重试 bootstrap（库打开失败后）：重置失败标记并重新初始化。
   * @returns 无返回值。
   */
  private retryBootstrap(): void {
    this.bootstrapFailed = false;
    this.vm = undefined;
    this.aboutToAppear();
  }

  /**
   * 更多菜单分发：本轮仅「详情」直接进入目录页（详情挂在目录页头部，F04 落地）；
   * 其余动作（校验/导出/更新/删除）属后续功能，本轮不接线，避免越权改动其它垂直切片。
   * @param book 目标书籍。
   * @param actionKey 动作标识。
   * @returns 无返回值。
   */
  private onMore(book: BookSummary, actionKey: string): void {
    if (actionKey === 'detail') {
      // 详情入口先进目录页（书籍详情面板由 F04 在目录页内承载）
      this.gotoCatalog(book);
    }
    // validate/export/update/delete 由后续功能轮接线，本轮不处理
  }

  /**
   * 进入导入选择页 P-F02（`import/select`）。
   * @returns 无返回值。
   */
  private gotoImport(): void {
    this.pageStack.pushPathByName(RouteName.IMPORT_SELECT, undefined);
  }

  /**
   * 进入书籍目录页 P-F04（`book`，param: bookId）。
   * @param book 目标书籍。
   * @returns 无返回值。
   */
  private gotoCatalog(book: BookSummary): void {
    // 目录页参数（书籍内部主键）
    const params: CatalogParams = { bookId: book.id };
    this.pageStack.pushPathByName(RouteName.CATALOG, params);
  }

  /**
   * 进入章节讲解页 P-F05（`lesson`，param: bookId/chapterId/section?）——继续学习上次章节。
   * 无续读目标时不跳转（按钮本不渲染，双保险）。
   * @param book 目标书籍。
   * @returns 无返回值。
   */
  private gotoLesson(book: BookSummary): void {
    // 续读目标（章节/小节定位），缺省则不跳转
    const target: ContinueTarget | undefined = book.continueTarget;
    if (target === undefined) {
      return;
    }
    // 讲解页参数：携带章节，sectionId 有则一并带上以精确续读
    const params: LessonParams = {
      bookId: book.id,
      chapterId: target.chapterId
    };
    if (target.sectionId !== undefined) {
      params.section = target.sectionId;
    }
    this.pageStack.pushPathByName(RouteName.LESSON, params);
  }
}
