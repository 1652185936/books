/**
 * table 内容块渲染组件（F05，LLD §6.5；映射为 GrammarTable）。
 * payload 形状：`{ columns: string[], rows: string[][] }`；plainText 为表头+单元格拼接（《06》§3.2）。
 */
import { ContentBlock } from '../../domain/entities/content';
import { BlockPayload, TableView } from './BlockPayload';
import { LessonTokens } from './LessonTokens';

@Component
export struct GrammarTable {
  /** 待渲染的 table 内容块。 */
  @Prop block: ContentBlock;

  /**
   * 渲染单行单元格（表头加粗、数据行常规）。
   * @param cells 单元格文本数组。
   * @param isHeader 是否表头行。
   */
  @Builder
  rowBuilder(cells: string[], isHeader: boolean) {
    Row() {
      ForEach(cells, (cell: string, index: number) => {
        Text(cell)
          .fontSize(LessonTokens.FONT_CAPTION + 1)
          .fontWeight(isHeader ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(isHeader ? LessonTokens.INK : LessonTokens.INK_SECONDARY)
          .padding({ top: 8, bottom: 8, left: 10, right: 10 })
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
      }, (cell: string, index: number) => `${index}-${cell}`)
    }
    .width('100%')
    .backgroundColor(isHeader ? LessonTokens.SURFACE : Color.White)
    .border({ width: { bottom: 1 }, color: LessonTokens.BORDER })
  }

  build() {
    // 表格视图（columns + rows）
    Column() {
      // 表头
      this.rowBuilder(BlockPayload.table(this.block.payload).columns, true)
      // 数据行
      ForEach(BlockPayload.table(this.block.payload).rows, (row: string[], index: number) => {
        this.rowBuilder(row, false)
      }, (row: string[], index: number) => `r${index}`)
    }
    .width('100%')
    .borderRadius(8)
    .border({ width: 1, color: LessonTokens.BORDER })
    .clip(true)
  }
}
