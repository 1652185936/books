/**
 * 题面分段展示组件（F06，LLD §6.6 主组件 SegmentedPrompt）。
 *
 * 展示练习指令（instruction）与题面文本（prompt.text，缺失回退指令）。题型徽标区分五种手写题型与四种
 * 非手写占位题型（R-063：非手写四种导入后保留并占位展示，作答交互列入后续迭代，CLAUDE.md §2-11）。
 * 用户可见文本走资源键（CLAUDE.md §5）；视觉常量取 ExerciseTokens。
 */
import { ExerciseDetail, ExerciseType } from '../../domain/entities/exercise';
import { JsonObject } from '../../domain/entities/common';
import { ExerciseTokens } from './ExerciseTokens';

/** 五种手写题型集合（F06 主流程作答；其余四种为占位）。 */
const HANDWRITING_TYPES: ExerciseType[] = [
  'fill-blank-handwriting', 'multi-blank-handwriting', 'rewrite-sentence-handwriting',
  'short-answer-handwriting', 'correction-handwriting'
];

@Component
export struct SegmentedPrompt {
  /** 练习详情（题面 + 题型）。 */
  @Prop detail: ExerciseDetail;

  /**
   * 从 prompt JsonObject 取题面文本（缺失/非字符串回退指令）。
   * @returns 题面文本字符串。
   */
  private promptText(): string {
    // 题面载体（协议 prompt_json 解析结果）
    const prompt: JsonObject = this.detail.prompt;
    // text 字段（可能缺失/非字符串）
    const value: string | number | boolean | null | JsonObject | JsonObject[] = prompt.text;
    if (typeof value === 'string' && value.length > 0) {
      return value;
    }
    return this.detail.instruction;
  }

  /**
   * 当前题型是否为五种手写题型之一（决定是否展示「占位题型」提示）。
   * @returns 手写题型返回 true。
   */
  private isHandwriting(): boolean {
    return HANDWRITING_TYPES.indexOf(this.detail.type) >= 0;
  }

  build() {
    Column({ space: 8 }) {
      // 指令（题目要求）
      if (this.detail.instruction.length > 0) {
        Text(this.detail.instruction)
          .fontSize(ExerciseTokens.FONT_HEADING)
          .fontWeight(FontWeight.Bold)
          .fontColor(ExerciseTokens.INK)
          .width('100%')
      }
      // 题面文本
      Text(this.promptText())
        .fontSize(ExerciseTokens.FONT_BODY)
        .fontColor(ExerciseTokens.INK)
        .lineHeight(ExerciseTokens.FONT_BODY + 10)
        .width('100%')
      // 非手写题型占位提示（R-063：保留并占位，不实现作答交互）
      if (!this.isHandwriting()) {
        Text($r('app.string.exercise_non_handwriting_placeholder'))
          .fontSize(ExerciseTokens.FONT_CAPTION)
          .fontColor(ExerciseTokens.WARN_AMBER)
          .width('100%')
          .padding({ top: 4, bottom: 4 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(ExerciseTokens.PAGE_PADDING)
    .backgroundColor(ExerciseTokens.SURFACE)
    .borderRadius(12)
  }
}
