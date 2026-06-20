/**
 * 书籍目录页 章节搜索框（F04，LLD §6.4 主组件 ChapterSearch）。
 *
 * 输入关键字驱动 `BooksRepository.searchChapters`（命中 title/titleZh，不区分大小写）。
 * 输入即上抛（页面 VM 去空白判定是否发起搜索并落「无匹配」态）；提供清空按钮回到全量列表。
 * 触控目标 ≥48vp（CLAUDE.md §6）；占位文案/按钮均走资源键（CLAUDE.md §5）。
 */
import { LessonTokens } from '../lesson/LessonTokens';

@Component
export struct ChapterSearch {
  /** 当前关键字（受控；与 VM.keyword 双向通过回调同步）。 */
  @Prop keyword: string;
  /** 关键字变化回调（页面/VM 据此搜索）。 */
  onKeywordChange: (keyword: string) => void = () => {};

  build() {
    Row({ space: 8 }) {
      // 搜索输入框（即时上抛，VM 去空白判定）
      TextInput({ text: this.keyword, placeholder: $r('app.string.catalog_search_placeholder') })
        .layoutWeight(1)
        .height(LessonTokens.TOUCH_MIN)
        .fontSize(LessonTokens.FONT_BODY)
        .backgroundColor(LessonTokens.SURFACE)
        .borderRadius(8)
        .onChange((value: string) => {
          this.onKeywordChange(value);
        })
      // 清空按钮（仅有关键字时显示）
      if (this.keyword.length > 0) {
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          Text($r('app.string.catalog_search_clear'))
            .fontSize(LessonTokens.FONT_CAPTION + 1)
            .fontColor(LessonTokens.INK_SECONDARY)
        }
        .backgroundColor(Color.Transparent)
        .height(LessonTokens.TOUCH_MIN)
        .constraintSize({ minWidth: LessonTokens.TOUCH_MIN })
        .borderRadius(8)
        .onClick(() => {
          this.onKeywordChange('');
        })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }
}
