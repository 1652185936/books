/**
 * 书籍目录页 章节列表（F04，LLD §6.4 主组件 ChapterList）。
 *
 * 左栏章节列表：展示标题（中文优先回退英文）、kind/时长、完成度百分比与进度状态徽标；点击选中预览。
 * 损坏章节置「章节损坏」徽标并弱化（选中预览仍可，「开始学习」由预览区据损坏态禁用）。
 * 左栏宽度 280..360vp 由页面控制（本组件填满父宽）；滚动位置由页面据 bookId 维护（onScroll 上抛）。
 * 触控目标 ≥48vp（CLAUDE.md §6）；所有可见文本走资源键（CLAUDE.md §5）。
 */
import { ChapterSummary } from '../../domain/entities/content';
import { Id } from '../../domain/entities/common';
import { LessonTokens } from '../lesson/LessonTokens';

@Component
export struct ChapterList {
  /** 待渲染章节列表（全量或搜索命中映射后的章节，按 order_no 升序）。 */
  @Prop chapters: ChapterSummary[];
  /** 当前选中章节 ID（高亮）。 */
  @Prop selectedChapterId: string;
  /** 损坏章节 ID 集合（置损坏徽标）。 */
  @Prop brokenChapterIds: Set<Id>;
  /** 列表初始滚动偏移（vp，页面按 bookId 恢复）。 */
  @Prop initialScrollOffset: number = 0;
  /** 选中章节回调（驱动预览区）。 */
  onSelectChapter: (chapterId: Id) => void = () => {};
  /** 滚动位置变化回调（页面据此按 bookId 保存）。 */
  onScrollOffsetChange: (offsetY: number) => void = () => {};
  /** 列表滚动控制器（用于恢复滚动位置）。 */
  private scroller: Scroller = new Scroller();

  /**
   * 进度状态徽标文案资源键（按 progressStatus 映射）。
   * @param status 进度状态。
   * @returns 文案资源键。
   */
  private progressLabel(status: ChapterSummary['progressStatus']): ResourceStr {
    if (status === 'completed') {
      return $r('app.string.catalog_progress_completed');
    }
    if (status === 'learning') {
      return $r('app.string.catalog_progress_learning');
    }
    if (status === 'review-due') {
      return $r('app.string.catalog_progress_review_due');
    }
    return $r('app.string.catalog_progress_not_started');
  }

  /**
   * 进度状态徽标颜色（完成=绿、复习到期=琥珀、其余=次要墨色，CLAUDE.md §6）。
   * @param status 进度状态。
   * @returns 颜色值。
   */
  private progressColor(status: ChapterSummary['progressStatus']): string {
    if (status === 'completed') {
      return LessonTokens.CORRECT_GREEN;
    }
    if (status === 'review-due') {
      return LessonTokens.WARN_AMBER;
    }
    if (status === 'learning') {
      return LessonTokens.BRAND_RED;
    }
    return LessonTokens.INK_MUTED;
  }

  /**
   * 单个章节行。
   * @param chapter 章节摘要。
   */
  @Builder
  chapterRow(chapter: ChapterSummary) {
    // 是否选中（高亮背景）
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        // 标题（中文优先回退英文）
        Text(chapter.titleZh.length > 0 ? chapter.titleZh : chapter.title)
          .fontSize(LessonTokens.FONT_BODY)
          .fontWeight(chapter.id === this.selectedChapterId ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.brokenChapterIds.has(chapter.id) ? LessonTokens.INK_MUTED : LessonTokens.INK)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        // 损坏徽标（损坏章节）
        if (this.brokenChapterIds.has(chapter.id)) {
          Text($r('app.string.catalog_chapter_broken_badge'))
            .fontSize(LessonTokens.FONT_CAPTION)
            .fontColor(LessonTokens.WARN_AMBER)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 10 }) {
        // 进度状态徽标
        Text(this.progressLabel(chapter.progressStatus))
          .fontSize(LessonTokens.FONT_CAPTION)
          .fontColor(this.progressColor(chapter.progressStatus))
        // 完成度百分比
        Text(`${Math.round(chapter.completionPercent)}%`)
          .fontSize(LessonTokens.FONT_CAPTION)
          .fontColor(LessonTokens.INK_SECONDARY)
        Blank()
        // 预计时长（数字 + 「分钟」单位标签，单位走资源键）
        Row({ space: 2 }) {
          Text(`${chapter.estimatedMinutes}`)
            .fontSize(LessonTokens.FONT_CAPTION)
            .fontColor(LessonTokens.INK_MUTED)
          Text($r('app.string.catalog_minutes_unit'))
            .fontSize(LessonTokens.FONT_CAPTION)
            .fontColor(LessonTokens.INK_MUTED)
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .constraintSize({ minHeight: LessonTokens.TOUCH_MIN })
    .backgroundColor(chapter.id === this.selectedChapterId ? LessonTokens.SURFACE : Color.White)
    .border({ width: { bottom: 1 }, color: LessonTokens.BORDER })
    .onClick(() => this.onSelectChapter(chapter.id))
  }

  build() {
    List({ scroller: this.scroller }) {
      ForEach(this.chapters, (chapter: ChapterSummary) => {
        ListItem() {
          this.chapterRow(chapter)
        }
      }, (chapter: ChapterSummary) => chapter.id)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Auto)
    .onScrollIndex((start: number) => {
      // 上抛当前首个可见项下标对应的近似偏移（页面据 bookId 保存恢复点）
      this.onScrollOffsetChange(this.scroller.currentOffset().yOffset);
    })
    .onAppear(() => {
      // 恢复上次滚动位置（页面按 bookId 下发 initialScrollOffset）
      if (this.initialScrollOffset > 0) {
        this.scroller.scrollTo({ xOffset: 0, yOffset: this.initialScrollOffset });
      }
    })
  }
}
