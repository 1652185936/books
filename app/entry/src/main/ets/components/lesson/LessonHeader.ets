/**
 * 章节讲解页头部（F05，LLD §6.5 主组件 LessonHeader）。
 *
 * 展示章节标题（title / titleZh）与目录、上一章、下一章、收藏入口。换章用上一章/下一章按钮 + 目录抽屉，
 * **禁止左右滑动换章**（避免与手写笔迹冲突，CLAUDE.md §2.6 / LLD §6.5 页面约束）。按钮回调上抛页面处理。
 * 触控目标 ≥48vp（§6）。所有可见文本走资源键（CLAUDE.md §5）。
 */
import { ChapterSummary } from '../../domain/entities/content';
import { LessonTokens } from './LessonTokens';

@Component
export struct LessonHeader {
  /** 当前章节摘要。 */
  @Prop chapter: ChapterSummary;
  /** 是否可进入上一章（首章时禁用）。 */
  @Prop canPrev: boolean;
  /** 是否可进入下一章（末章时禁用）。 */
  @Prop canNext: boolean;
  /** 是否已收藏本章（控制收藏图标态）。 */
  @Prop bookmarked: boolean = false;
  /** 打开目录抽屉回调。 */
  onOpenDrawer: () => void = () => {};
  /** 上一章回调。 */
  onPrevChapter: () => void = () => {};
  /** 下一章回调。 */
  onNextChapter: () => void = () => {};
  /** 切换收藏回调。 */
  onToggleBookmark: () => void = () => {};

  /**
   * 标题栏文本按钮（统一触控尺寸与禁用态样式）。
   * @param label 文案资源。
   * @param enabled 是否可点。
   * @param action 点击回调。
   */
  @Builder
  navButton(label: ResourceStr, enabled: boolean, action: () => void) {
    Text(label)
      .fontSize(LessonTokens.FONT_CAPTION + 1)
      .fontColor(enabled ? LessonTokens.BRAND_RED : LessonTokens.INK_MUTED)
      .padding({ left: 12, right: 12 })
      .height(LessonTokens.TOUCH_MIN)
      .constraintSize({ minWidth: LessonTokens.TOUCH_MIN })
      .textAlign(TextAlign.Center)
      .enabled(enabled)
      .onClick(() => {
        if (enabled) {
          action();
        }
      })
  }

  build() {
    Row({ space: 4 }) {
      // 目录抽屉入口
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        Text($r('app.string.lesson_open_drawer'))
          .fontSize(LessonTokens.FONT_CAPTION + 1)
          .fontColor(LessonTokens.INK)
      }
      .backgroundColor(Color.Transparent)
      .height(LessonTokens.TOUCH_MIN)
      .constraintSize({ minWidth: LessonTokens.TOUCH_MIN })
      .borderRadius(8)
      .onClick(() => this.onOpenDrawer())

      // 章节标题（中文优先，回退英文）
      Column({ space: 2 }) {
        Text(this.chapter.titleZh.length > 0 ? this.chapter.titleZh : this.chapter.title)
          .fontSize(LessonTokens.FONT_HEADING)
          .fontWeight(FontWeight.Bold)
          .fontColor(LessonTokens.INK)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.chapter.titleZh.length > 0 && this.chapter.title.length > 0) {
          Text(this.chapter.title)
            .fontSize(LessonTokens.FONT_CAPTION)
            .fontColor(LessonTokens.INK_SECONDARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 上一章 / 下一章（禁止滑动换章，仅按钮）
      this.navButton($r('app.string.lesson_prev_chapter'), this.canPrev, () => this.onPrevChapter())
      this.navButton($r('app.string.lesson_next_chapter'), this.canNext, () => this.onNextChapter())

      // 收藏
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        Text(this.bookmarked ? $r('app.string.lesson_bookmarked') : $r('app.string.lesson_bookmark'))
          .fontSize(LessonTokens.FONT_CAPTION + 1)
          .fontColor(this.bookmarked ? LessonTokens.BRAND_RED : LessonTokens.INK_SECONDARY)
      }
      .backgroundColor(Color.Transparent)
      .height(LessonTokens.TOUCH_MIN)
      .constraintSize({ minWidth: LessonTokens.TOUCH_MIN })
      .borderRadius(8)
      .onClick(() => this.onToggleBookmark())
    }
    .width('100%')
    .height(56)
    .padding({ left: LessonTokens.PAGE_PADDING, right: LessonTokens.PAGE_PADDING })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Color.White)
    .border({ width: { bottom: 1 }, color: LessonTokens.BORDER })
  }
}
