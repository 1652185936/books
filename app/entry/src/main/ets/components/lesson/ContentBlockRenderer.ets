/**
 * 内容块分发渲染器（F05，LLD §6.5 内容块映射表 + R-036）。
 *
 * 按 `block.type` 把内容块分发到对应渲染组件（11 种白名单）；未在白名单内的 type 走 `UnsupportedBlock`
 * 兜底（显示「暂不支持的内容块」而非崩溃，R-036），不静默丢弃、不白屏。白名单与协议 §5.2 / 04 契约
 * `ContentBlock.type` 逐一对齐：
 *   heading / paragraph / formula / example / example-list / bullet-list /
 *   table / timeline / callout / illustration / audio-text。
 *
 * illustration / audio-text 的资源（图片/音频）由页面经 ContentRepository.getAssetUri 解析为可加载 URI
 * 后通过 `resolveImageUri` 注入；缺资源时各组件局部走资源缺失态（LLD §6.5「资源缺失」状态）。
 */
import { ContentBlock } from '../../domain/entities/content';
import { ContentHeading } from './ContentHeading';
import { ContentParagraph } from './ContentParagraph';
import { FormulaRow } from './FormulaRow';
import { ExampleCard } from './ExampleCard';
import { ExampleList } from './ExampleList';
import { BulletList } from './BulletList';
import { GrammarTable } from './GrammarTable';
import { TenseTimeline } from './TenseTimeline';
import { CalloutCard } from './CalloutCard';
import { LessonIllustration } from './LessonIllustration';
import { AudioTextBlock } from './AudioTextBlock';
import { UnsupportedBlock } from './UnsupportedBlock';

/** 协议 §5.2 的 11 种内容块渲染白名单（R-036 判定的唯一权威来源）。 */
const RENDER_WHITELIST: string[] = [
  'heading', 'paragraph', 'formula', 'example', 'example-list',
  'bullet-list', 'table', 'timeline', 'callout', 'illustration', 'audio-text'
];

@Component
export struct ContentBlockRenderer {
  /** 待分发渲染的内容块。 */
  @Prop block: ContentBlock;
  /** illustration 的已解析图片 URI（页面注入，缺图为空串→资源缺失态）。 */
  @Prop resolvedImageUri: string = '';

  build() {
    // 按 type 分发；白名单外走 UnsupportedBlock（R-036）
    if (this.block.type === 'heading') {
      ContentHeading({ block: this.block })
    } else if (this.block.type === 'paragraph') {
      ContentParagraph({ block: this.block })
    } else if (this.block.type === 'formula') {
      FormulaRow({ block: this.block })
    } else if (this.block.type === 'example') {
      ExampleCard({ block: this.block })
    } else if (this.block.type === 'example-list') {
      ExampleList({ block: this.block })
    } else if (this.block.type === 'bullet-list') {
      BulletList({ block: this.block })
    } else if (this.block.type === 'table') {
      GrammarTable({ block: this.block })
    } else if (this.block.type === 'timeline') {
      TenseTimeline({ block: this.block })
    } else if (this.block.type === 'callout') {
      CalloutCard({ block: this.block })
    } else if (this.block.type === 'illustration') {
      LessonIllustration({ block: this.block, resolvedImageUri: this.resolvedImageUri })
    } else if (this.block.type === 'audio-text') {
      AudioTextBlock({ block: this.block, hasAudio: this.block.assetUri !== undefined })
    } else {
      // R-036：未知 type 兜底，不崩溃、不白屏
      UnsupportedBlock({ block: this.block })
    }
  }

  /**
   * 判断 type 是否在渲染白名单内（供页面预判/测试复用，与 build 分发口径同源）。
   * @param type 内容块 type。
   * @returns 在白名单内返回 true。
   */
  static isSupported(type: string): boolean {
    return RENDER_WHITELIST.indexOf(type) >= 0;
  }
}
