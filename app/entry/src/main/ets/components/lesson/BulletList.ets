/**
 * bullet-list 内容块渲染组件（F05，LLD §6.5；D5 新增项）。
 * payload 形状：`{ items: (string | { text })[] }`；plainText 为各项换行拼接（《06》§3.2）。
 */
import { ContentBlock } from '../../domain/entities/content';
import { BlockPayload } from './BlockPayload';
import { LessonTokens } from './LessonTokens';

@Component
export struct BulletList {
  /** 待渲染的 bullet-list 内容块。 */
  @Prop block: ContentBlock;

  build() {
    Column({ space: 8 }) {
      ForEach(BlockPayload.listItems(this.block.payload), (item: string, index: number) => {
        Row({ space: 8 }) {
          // 项目符号
          Text('•')
            .fontSize(LessonTokens.FONT_BODY)
            .fontColor(LessonTokens.BRAND_RED)
            .width(14)
          Text(item)
            .fontSize(LessonTokens.FONT_BODY)
            .fontColor(LessonTokens.INK)
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (item: string, index: number) => `${index}-${item}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
