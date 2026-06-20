/**
 * 目录抽屉（F05，LLD §6.5 主组件 ChapterDrawer）。
 *
 * 从左侧滑出的章节目录，点击章节项跳转换章。是「禁止左右滑动换章」约束下的换章主入口之一
 * （另一为 LessonHeader 的上一章/下一章按钮，CLAUDE.md §2.6 / LLD §6.5）。当前章高亮，点击遮罩或章节项关闭。
 * 章节列表由页面经 BooksRepository.listChapters 提供（本组件只接收 ChapterSummary[] 渲染，不查 SQL）。
 */
import { ChapterSummary } from '../../domain/entities/content';
import { Id } from '../../domain/entities/common';
import { LessonTokens } from './LessonTokens';

@Component
export struct ChapterDrawer {
  /** 是否展开。 */
  @Prop visible: boolean;
  /** 全书章节列表（按 order 升序）。 */
  @Prop chapters: ChapterSummary[];
  /** 当前章节 ID（高亮）。 */
  @Prop currentChapterId: Id;
  /** 选择某章回调（参数为章节 ID）。 */
  onSelectChapter: (chapterId: Id) => void = () => {};
  /** 关闭抽屉回调。 */
  onClose: () => void = () => {};

  build() {
    if (this.visible) {
      Stack({ alignContent: Alignment.Start }) {
        // 遮罩（点击关闭）
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(LessonTokens.SCRIM)
          .onClick(() => this.onClose())

        // 抽屉面板
        Column() {
          // 抽屉标题
          Row() {
            Text($r('app.string.lesson_drawer_title'))
              .fontSize(LessonTokens.FONT_HEADING)
              .fontWeight(FontWeight.Bold)
              .fontColor(LessonTokens.INK)
              .layoutWeight(1)
            Text($r('app.string.lesson_drawer_close'))
              .fontSize(LessonTokens.FONT_CAPTION + 1)
              .fontColor(LessonTokens.INK_SECONDARY)
              .height(LessonTokens.TOUCH_MIN)
              .padding({ left: 8, right: 8 })
              .onClick(() => this.onClose())
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .alignItems(VerticalAlign.Center)
          .border({ width: { bottom: 1 }, color: LessonTokens.BORDER })

          // 章节列表
          List() {
            ForEach(this.chapters, (chapter: ChapterSummary, index: number) => {
              ListItem() {
                Row({ space: 8 }) {
                  Text(`${chapter.orderNo}`)
                    .fontSize(LessonTokens.FONT_CAPTION)
                    .fontColor(LessonTokens.INK_MUTED)
                    .width(28)
                  Text(chapter.titleZh.length > 0 ? chapter.titleZh : chapter.title)
                    .fontSize(LessonTokens.FONT_BODY)
                    .fontColor(chapter.id === this.currentChapterId
                      ? LessonTokens.BRAND_RED : LessonTokens.INK)
                    .fontWeight(chapter.id === this.currentChapterId
                      ? FontWeight.Bold : FontWeight.Normal)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                }
                .width('100%')
                .padding({ top: 12, bottom: 12, left: 16, right: 16 })
                .constraintSize({ minHeight: LessonTokens.TOUCH_MIN })
                .alignItems(VerticalAlign.Center)
                .onClick(() => this.onSelectChapter(chapter.id))
              }
            }, (chapter: ChapterSummary, index: number) => `${index}-${chapter.id}`)
          }
          .layoutWeight(1)
          .width('100%')
          .divider({ strokeWidth: 1, color: LessonTokens.BORDER })
        }
        .width(360)
        .height('100%')
        .backgroundColor(Color.White)
      }
      .width('100%')
      .height('100%')
    }
  }
}
