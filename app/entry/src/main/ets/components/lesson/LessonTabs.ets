/**
 * 小节标签条（F05，LLD §6.5 主组件 LessonTabs）。
 *
 * 横向标签切换章节内小节（不依赖左右滑动换章；小节切换为标签点击，章切换走 LessonHeader）。
 * 标签由小节标题构成，缺标题时回退「小节 N」。点击回调上抛页面，由 LessonVM.switchSection 处理
 * （切换前保存阅读锚点，R-034）。当前激活标签用品牌红下划线强调（§6）。触控目标 ≥48vp。
 */
import { SectionContent } from '../../domain/entities/content';
import { LessonTokens } from './LessonTokens';

@Component
export struct LessonTabs {
  /** 小节列表。 */
  @Prop sections: SectionContent[];
  /** 当前激活小节下标。 */
  @Prop activeIndex: number;
  /** 切换小节回调（参数为目标下标）。 */
  onSwitch: (index: number) => void = () => {};

  /**
   * 取小节标签文案：有标题用标题，否则回退「小节 N」（资源键 + 占位）。
   * @param section 小节。
   * @param index 下标。
   * @returns 标签文本。
   */
  private tabLabel(section: SectionContent, index: number): string {
    return section.title.length > 0 ? section.title : `${index + 1}`;
  }

  build() {
    Scroll() {
      Row({ space: 4 }) {
        ForEach(this.sections, (section: SectionContent, index: number) => {
          Column({ space: 4 }) {
            Text(this.tabLabel(section, index))
              .fontSize(LessonTokens.FONT_BODY)
              .fontWeight(index === this.activeIndex ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(index === this.activeIndex ? LessonTokens.BRAND_RED : LessonTokens.INK_SECONDARY)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            // 激活下划线
            Divider()
              .strokeWidth(2)
              .color(index === this.activeIndex ? LessonTokens.BRAND_RED : Color.Transparent)
              .width('100%')
          }
          .padding({ left: 12, right: 12 })
          .height(LessonTokens.TOUCH_MIN)
          .justifyContent(FlexAlign.Center)
          .constraintSize({ minWidth: LessonTokens.TOUCH_MIN, maxWidth: 200 })
          .onClick(() => this.onSwitch(index))
        }, (section: SectionContent, index: number) => `${index}-${section.id}`)
      }
      .padding({ left: LessonTokens.PAGE_PADDING, right: LessonTokens.PAGE_PADDING })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .backgroundColor(Color.White)
    .border({ width: { bottom: 1 }, color: LessonTokens.BORDER })
  }
}
