/**
 * formula 内容块渲染组件（F05，LLD §6.5）。
 * payload 形状：`{ parts: [{ text, role? }] }`；plainText 为各 parts[].text 空格拼接（《06》§3.2）。
 * 以横向片段流呈现「主语+谓语+...」结构，role 用于轻量着色（不依赖原书插图）。
 */
import { ContentBlock } from '../../domain/entities/content';
import { BlockPayload, FormulaPart } from './BlockPayload';
import { LessonTokens } from './LessonTokens';

@Component
export struct FormulaRow {
  /** 待渲染的 formula 内容块。 */
  @Prop block: ContentBlock;

  /**
   * 按片段 role 取强调色：动词/助动词类用品牌红强调，其余用正文色。
   * @param role 片段角色。
   * @returns 字体颜色。
   */
  private colorForRole(role: string): string {
    if (role === 'verb' || role === 'auxiliary' || role === 'operator') {
      return LessonTokens.BRAND_RED;
    }
    return LessonTokens.INK;
  }

  build() {
    Row({ space: 8 }) {
      ForEach(BlockPayload.formulaParts(this.block.payload), (part: FormulaPart, index: number) => {
        Text(part.text)
          .fontSize(LessonTokens.FONT_HEADING)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colorForRole(part.role))
      }, (part: FormulaPart, index: number) => `${index}-${part.text}`)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8, left: 12, right: 12 })
    .backgroundColor(LessonTokens.SURFACE)
    .borderRadius(8)
  }
}
