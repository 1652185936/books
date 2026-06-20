/**
 * heading 内容块渲染组件（F05，LLD §6.5 内容块映射表）。
 * payload 形状：`{ text, level? }`（level 影响层级字号）；plainText 取 text（《06》§3.2）。
 */
import { ContentBlock } from '../../domain/entities/content';
import { BlockPayload } from './BlockPayload';
import { LessonTokens } from './LessonTokens';

@Component
export struct ContentHeading {
  /** 待渲染的 heading 内容块。 */
  @Prop block: ContentBlock;

  /**
   * 由 heading.level 推导字号：level 越小字号越大；缺省按二级。
   * @returns 字号（vp）。
   */
  private headingFontSize(): number {
    // 标题层级（1..6，缺省 2）
    const level: number = BlockPayload.num(this.block.payload, 'level', 2);
    if (level <= 1) {
      return LessonTokens.FONT_TITLE;
    }
    if (level >= 3) {
      return LessonTokens.FONT_BODY + 1;
    }
    return LessonTokens.FONT_HEADING;
  }

  build() {
    Text(BlockPayload.str(this.block.payload, 'text', this.block.plainText))
      .fontSize(this.headingFontSize())
      .fontWeight(FontWeight.Bold)
      .fontColor(LessonTokens.INK)
      .width('100%')
  }
}
