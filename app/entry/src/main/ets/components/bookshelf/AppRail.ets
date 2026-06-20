import { ImportButton } from './ImportButton';

/** 排序选项标识（与 `BookListQuery.sort` 同集合）。 */
export type RailSortKey = 'last-opened' | 'title' | 'imported-at';

/**
 * 书架左侧应用导航栏（F01，LLD §6.1 AppRail）。
 *
 * 平板横屏基线（CLAUDE.md §6）下置于书架左侧：顶部为应用标识，中部为排序切换段，底部为导入入口槽（由父组件注入）。
 * 自身只负责排序选择上抛与导入点击上抛，不持有数据/路由。所有文案取自资源（CLAUDE.md §5）。
 */
@Component
export struct AppRail {
  /** 当前选中的排序方式（受控，父组件状态驱动）。 */
  @Prop sort: RailSortKey;
  /** 排序切换回调。 */
  onSortChange?: (sort: RailSortKey) => void;
  /** 导入按钮点击回调（进入 P-F02 `import/select`）。 */
  onImport?: () => void;

  /**
   * 排序选项表（label 为资源引用，key 为稳定排序标识）。
   */
  private readonly sortItems: Array<Record<string, string | Resource>> = [
    { key: 'last-opened', label: $r('app.string.bookshelf_sort_last_opened') },
    { key: 'title', label: $r('app.string.bookshelf_sort_title') },
    { key: 'imported-at', label: $r('app.string.bookshelf_sort_imported') }
  ];

  build() {
    Column({ space: 12 }) {
      // 应用标识区
      Text($r('app.string.route_title_bookshelf'))
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .padding({ top: 8, bottom: 8 })
      // 排序段标题
      Text($r('app.string.bookshelf_sort_label'))
        .fontSize(13)
        .fontColor('#6B7280')
        .width('100%')
      // 排序选项列表（48vp 触控目标，CLAUDE.md §6）
      ForEach(this.sortItems, (item: Record<string, string | Resource>): void => {
        Row() {
          Text(item.label as ResourceStr)
            .fontSize(15)
            .fontColor(this.sort === item.key ? '#C0392B' : '#374151')
            .fontWeight(this.sort === item.key ? FontWeight.Medium : FontWeight.Normal)
        }
        .width('100%')
        .height(48)
        .padding({ left: 12, right: 12 })
        .borderRadius(8)
        .backgroundColor(this.sort === item.key ? '#FBEAE8' : Color.Transparent)
        .alignItems(VerticalAlign.Center)
        .onClick((): void => {
          if (this.onSortChange !== undefined) {
            this.onSortChange(item.key as RailSortKey)
          }
        })
      }, (item: Record<string, string | Resource>): string => item.key as string)

      // 弹性占位：把导入按钮推到底部
      Blank()

      // 导入入口（复用 ImportButton：主操作 56vp + 防重复点击，CLAUDE.md §6）
      ImportButton({ onImport: this.onImport })
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor('#F7F8FA')
  }
}
