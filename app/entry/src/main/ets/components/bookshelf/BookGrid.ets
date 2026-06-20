import { BookSummary } from '../../domain/entities/content';
import { BookCard } from './BookCard';

/** 卡片最小列宽（vp，LLD §6.1：卡片最小宽 230 vp）——栅格按此自适应列数。 */
const CARD_MIN_WIDTH: number = 230;

/**
 * 书架数据源（LazyForEach 懒加载，LLD §6.1：100 本书使用懒加载）。
 *
 * 实现 `IDataSource`：仅渲染可视区卡片，列表整体替换时一次性通知刷新。
 * 大列表（100 本）下避免一次性创建全部组件树，满足懒加载约束。
 */
class BookDataSource implements IDataSource {
  /** 当前书籍列表（整体替换式更新）。 */
  private books: BookSummary[] = [];
  /** 数据变更监听器集合（LazyForEach 注册）。 */
  private listeners: DataChangeListener[] = [];

  /**
   * 取总条数。
   * @returns 列表长度。
   */
  totalCount(): number {
    return this.books.length;
  }

  /**
   * 取指定下标的书籍。
   * @param index 下标。
   * @returns 该位置的书籍摘要。
   */
  getData(index: number): BookSummary {
    return this.books[index];
  }

  /**
   * 注册数据变更监听器（LazyForEach 调用）。
   * @param listener 监听器。
   * @returns 无返回值。
   */
  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  /**
   * 注销数据变更监听器（LazyForEach 调用）。
   * @param listener 监听器。
   * @returns 无返回值。
   */
  unregisterDataChangeListener(listener: DataChangeListener): void {
    // 监听器下标
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  /**
   * 整体替换数据并通知 LazyForEach 全量重载（排序/过滤/刷新场景）。
   * @param books 新书籍列表。
   * @returns 无返回值。
   */
  setBooks(books: BookSummary[]): void {
    this.books = books;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

/**
 * 书架栅格（F01，LLD §6.1 BookGrid）。
 *
 * 以 Grid + LazyForEach 渲染书卡，列宽按 `230vp` 最小宽自适应（`GridLayoutOptions` 由 `columnsTemplate` 表达）。
 * 父组件经 `@Prop books` 传入列表，内部桥接到 `BookDataSource` 做懒加载；卡片交互回调透传给父组件。
 */
@Component
export struct BookGrid {
  /** 当前书籍列表（父组件状态驱动；变更时经 @Watch 同步数据源）。 */
  @Prop @Watch('onBooksChanged') books: BookSummary[];
  /** 卡片点击（进目录）回调。 */
  onOpen?: (book: BookSummary) => void;
  /** 继续学习回调。 */
  onContinue?: (book: BookSummary) => void;
  /** 更多菜单回调。 */
  onMore?: (book: BookSummary, actionKey: string) => void;

  /** 懒加载数据源（books 变更时同步）。 */
  private dataSource: BookDataSource = new BookDataSource();

  /**
   * 组件即将出现：用初始 books 填充数据源。
   * @returns 无返回值。
   */
  aboutToAppear(): void {
    this.dataSource.setBooks(this.books);
  }

  /**
   * books 变更回调（@Watch）：整体替换数据源并触发懒加载全量重载。
   * @returns 无返回值。
   */
  onBooksChanged(): void {
    this.dataSource.setBooks(this.books);
  }

  build() {
    Grid() {
      LazyForEach(this.dataSource, (book: BookSummary): void => {
        GridItem() {
          BookCard({
            book: book,
            onOpen: this.onOpen,
            onContinue: this.onContinue,
            onMore: this.onMore
          })
        }
      }, (book: BookSummary): string => book.id)
    }
    // 列宽按最小 230vp 自适应：在 1280vp 基线下约 4~5 列（GridRow 风格用 columnsTemplate 近似）
    .columnsTemplate('1fr 1fr 1fr 1fr')
    .columnsGap(16)
    .rowsGap(16)
    .cachedCount(4)
    .width('100%')
    .height('100%')
    .padding(16)
  }
}
