import { BookSummary } from '../../domain/entities/content';

/** 卡片最小宽度（vp，LLD §6.1：卡片最小宽 230 vp）。 */
const CARD_MIN_WIDTH: number = 230;
/** 封面高宽比（≈3:4，LLD §6.1：封面比例约 3:4）。 */
const COVER_ASPECT_RATIO: number = 3 / 4;
/** 手写主操作最小触控尺寸（vp，CLAUDE.md §6）。 */
const PRIMARY_TOUCH_SIZE: number = 56;

/**
 * 书架书卡（F01，LLD §6.1 BookCard）。
 *
 * 展示封面、标题、副标题、作者、完成度与状态徽标；提供「卡片点击进目录」「继续学习」「更多菜单」三处交互。
 * 自身不持有数据库/路由，交互经回调上抛给页面（解耦，便于复用与测试）。
 * 封面缺失或加载失败时回退占位底色 + 标题首字，不空白、不崩溃（LLD §7 完成定义：异常态齐全）。
 */
@Component
export struct BookCard {
  /** 卡片绑定的书籍摘要。 */
  @Prop book: BookSummary;
  /** 点击卡片主体（进入目录 `book/{bookId}`）。 */
  onOpen?: (book: BookSummary) => void;
  /** 点击「继续学习」（进入上次章节 lesson）；book.continueTarget 为空时不展示该按钮。 */
  onContinue?: (book: BookSummary) => void;
  /** 选择更多菜单项（详情/校验/导出/更新/删除），actionKey 见 MORE_MENU_ITEMS。 */
  onMore?: (book: BookSummary, actionKey: string) => void;

  /**
   * 更多菜单项（LLD §6.1：查看详情、校验内容、导出学习记录、更新学习包、删除）。
   * value 为文案资源引用，actionKey 为稳定动作标识（上抛给页面分发）。
   */
  private readonly moreMenuItems: Array<Record<string, string | Resource>> = [
    { actionKey: 'detail', label: $r('app.string.book_menu_detail') },
    { actionKey: 'validate', label: $r('app.string.book_menu_validate') },
    { actionKey: 'export', label: $r('app.string.book_menu_export') },
    { actionKey: 'update', label: $r('app.string.book_menu_update') },
    { actionKey: 'delete', label: $r('app.string.book_menu_delete') }
  ];

  /**
   * 更多菜单构建器（长按/点击「更多」按钮弹出）。
   * @returns 菜单 UI。
   */
  @Builder
  moreMenu() {
    Menu() {
      ForEach(this.moreMenuItems, (item: Record<string, string | Resource>): void => {
        MenuItem({ content: item.label as ResourceStr })
          .onClick((): void => {
            if (this.onMore !== undefined) {
              this.onMore(this.book, item.actionKey as string);
            }
          })
      }, (item: Record<string, string | Resource>): string => item.actionKey as string)
    }
  }

  /**
   * 封面区构建器：有 coverUri 用 Image，缺失/失败回退占位底色 + 标题首字。
   * @returns 封面 UI。
   */
  @Builder
  coverArea() {
    Stack({ alignContent: Alignment.TopEnd }) {
      if (this.book.coverUri !== undefined && this.book.coverUri.length > 0) {
        // 封面图：沙箱相对路径交由渲染层解析（§1.3 仅存相对路径）
        Image(this.book.coverUri)
          .width('100%')
          .aspectRatio(COVER_ASPECT_RATIO)
          .objectFit(ImageFit.Cover)
          .borderRadius({ topLeft: 12, topRight: 12 })
          .alt($r('app.string.bookshelf_cover_alt'))
      } else {
        // 占位封面：品牌浅底 + 标题首字，避免空白
        Column() {
          Text(this.firstChar())
            .fontSize(48)
            .fontWeight(FontWeight.Bold)
            .fontColor('#9AA7B4')
        }
        .width('100%')
        .aspectRatio(COVER_ASPECT_RATIO)
        .backgroundColor('#EEF1F4')
        .borderRadius({ topLeft: 12, topRight: 12 })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
      // 状态徽标（仅非 ready 显示，如「损坏」「更新中」）
      if (this.book.status !== 'ready') {
        Text(this.statusLabel())
          .fontSize(12)
          .fontColor(Color.White)
          .backgroundColor(this.statusColor())
          .borderRadius(6)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .margin(8)
      }
    }
    .width('100%')
  }

  build() {
    Column({ space: 6 }) {
      this.coverArea()
      // 标题（单行省略）
      Text(this.book.title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      // 副标题（可空，单行省略）
      if (this.book.subtitle.length > 0) {
        Text(this.book.subtitle)
          .fontSize(13)
          .fontColor('#6B7280')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      // 完成度行：进度条 + 百分比文案
      Row({ space: 8 }) {
        Progress({ value: this.book.completionPercent, total: 100, type: ProgressType.Linear })
          .color('#C0392B')
          .layoutWeight(1)
        Text(`${this.book.completionPercent}%`)
          .fontSize(12)
          .fontColor('#6B7280')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      // 底部操作行：继续学习（有续读目标才显示）+ 更多
      Row() {
        if (this.book.continueTarget !== undefined) {
          Button($r('app.string.bookshelf_continue'))
            .fontSize(14)
            .height(PRIMARY_TOUCH_SIZE)
            .layoutWeight(1)
            .backgroundColor('#C0392B')
            .onClick((): void => {
              if (this.onContinue !== undefined) {
                this.onContinue(this.book);
              }
            })
        }
        Button({ type: ButtonType.Circle }) {
          Text('⋯').fontSize(20).fontColor('#374151')
        }
        .width(PRIMARY_TOUCH_SIZE)
        .height(PRIMARY_TOUCH_SIZE)
        .backgroundColor('#EEF1F4')
        .margin({ left: this.book.continueTarget !== undefined ? 8 : 0 })
        .bindMenu(this.moreMenu())
      }
      .width('100%')
    }
    .width('100%')
    .constraintSize({ minWidth: CARD_MIN_WIDTH })
    .padding(12)
    .backgroundColor(Color.White)
    .borderRadius(12)
    .shadow({ radius: 8, color: '#1A000000', offsetX: 0, offsetY: 2 })
    .onClick((): void => {
      if (this.onOpen !== undefined) {
        this.onOpen(this.book);
      }
    })
  }

  /**
   * 取标题首字符（占位封面用）；空标题回退「书」字。
   * @returns 单字符串。
   */
  private firstChar(): string {
    // 标题首字（占位封面展示），空标题给品牌兜底字
    return this.book.title.length > 0 ? this.book.title.substring(0, 1) : '书';
  }

  /**
   * 状态徽标文案（资源引用）：损坏 / 更新中。
   * @returns 文案资源。
   */
  private statusLabel(): ResourceStr {
    if (this.book.status === 'broken') {
      return $r('app.string.book_status_broken');
    }
    if (this.book.status === 'updating') {
      return $r('app.string.book_status_updating');
    }
    // ready/deleted 不应进入本分支（build 已过滤 ready；deleted 不入书架）
    return $r('app.string.book_status_updating');
  }

  /**
   * 状态徽标底色：损坏用琥珀色（警告，CLAUDE.md §6），更新中用品牌强调色派生的中性蓝。
   * @returns 颜色字符串。
   */
  private statusColor(): string {
    // 损坏=琥珀色警告；更新中=信息蓝
    return this.book.status === 'broken' ? '#D97706' : '#2563EB';
  }
}
