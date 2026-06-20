/**
 * timeline 内容块渲染组件（F05，LLD §6.5；映射为 TenseTimeline）。
 * payload 形状：`{ events: [{ title, description }] }`（兼容 nodes）；plainText 为各节点拼接（《06》§3.2）。
 */
import { ContentBlock } from '../../domain/entities/content';
import { BlockPayload, TimelineNode } from './BlockPayload';
import { LessonTokens } from './LessonTokens';

@Component
export struct TenseTimeline {
  /** 待渲染的 timeline 内容块。 */
  @Prop block: ContentBlock;

  build() {
    Column({ space: 0 }) {
      ForEach(BlockPayload.timelineNodes(this.block.payload), (node: TimelineNode, index: number) => {
        Row({ space: 12 }) {
          // 时间轴竖线 + 节点圆点
          Column() {
            Circle({ width: 12, height: 12 })
              .fill(LessonTokens.BRAND_RED)
            Divider()
              .vertical(true)
              .strokeWidth(2)
              .color(LessonTokens.BORDER)
              .layoutWeight(1)
          }
          .width(16)
          .alignItems(HorizontalAlign.Center)

          Column({ space: 4 }) {
            Text(node.title)
              .fontSize(LessonTokens.FONT_BODY)
              .fontWeight(FontWeight.Medium)
              .fontColor(LessonTokens.INK)
              .width('100%')
            Text(node.description)
              .fontSize(LessonTokens.FONT_CAPTION + 1)
              .fontColor(LessonTokens.INK_SECONDARY)
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .padding({ bottom: 14 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (node: TimelineNode, index: number) => `${index}-${node.title}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
