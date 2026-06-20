/**
 * 校验阶段网格（P-F03 主组件 `ValidationStageGrid`，LLD §6.3）。
 *
 * 横向逐行展示六个校验阶段（不解压安全/manifest/解压暂存/SHA-256/Schema/业务）的进度标记：
 * pending（待校验，置灰）/ active（校验中，品牌强调）/ done（通过，绿）/ failed（阻断，红）。
 * 进度只前进不回退（§6.3 页面约束）：由 VM 保证标记单调推进，本组件仅按外部标记渲染。
 *
 * 纯展示组件：零 IO、零业务状态。可见文案取资源（CLAUDE.md §5），不在组件内硬编码。
 *
 * 未编译验证（缺 HarmonyOS SDK）：ArkUI 组件与 `$r` 资源解析以 API 12 为准。
 */
import { StageMark } from '../../viewmodels/ImportValidateVM';

/** 单个阶段渲染定义（阶段标题资源键 + 当前标记）。 */
export interface StageItem {
  /** 阶段标题字符串资源名（element/string.json）。 */
  titleKey: string;
  /** 阶段标记态。 */
  mark: StageMark;
}

/** 标记 → 圆点背景色（绿/红/品牌红/灰，遵 UI 约束 §6：正确绿、阻断红、强调品牌红）。 */
const MARK_DOT_COLOR: Record<string, string> = {
  done: '#2BA471',
  failed: '#C03B3B',
  active: '#C03B3B',
  pending: '#E8EAED'
};

/** 标记 → 圆点内符号（✓ 通过 / ! 失败 / · 进行/待）。 */
const MARK_SYMBOL: Record<string, string> = {
  done: '✓',
  failed: '!',
  active: '…',
  pending: ''
};

/**
 * 校验阶段网格组件。
 */
@Component
export struct ValidationStageGrid {
  /** 六阶段渲染定义（标题资源键 + 标记；由页面据 VM 组装）。 */
  @Prop stages: StageItem[];

  /**
   * 取标记对应圆点背景色（未命中回退 pending 灰）。
   * @param mark 阶段标记。
   * @returns 颜色串。
   */
  private dotColor(mark: StageMark): string {
    // 命中色或回退
    const color: string | undefined = MARK_DOT_COLOR[mark];
    return color !== undefined ? color : MARK_DOT_COLOR.pending;
  }

  /**
   * 取标记对应圆点内符号。
   * @param mark 阶段标记。
   * @returns 符号串。
   */
  private symbol(mark: StageMark): string {
    // 命中符号或空
    const s: string | undefined = MARK_SYMBOL[mark];
    return s !== undefined ? s : '';
  }

  /**
   * 渲染单个阶段行（圆点 + 标题）。
   * @param item 阶段定义。
   * @returns 无（@Builder 子树）。
   */
  @Builder
  stageRow(item: StageItem) {
    Row({ space: 12 }) {
      // 阶段状态圆点
      Text(this.symbol(item.mark))
        .width(28)
        .height(28)
        .borderRadius(14)
        .textAlign(TextAlign.Center)
        .fontSize(15)
        .fontColor(item.mark === 'pending' ? '#9AA0A6' : Color.White)
        .backgroundColor(this.dotColor(item.mark))
      // 阶段标题（active 用强调色，其余常规）
      Text($r(`app.string.${item.titleKey}`))
        .fontSize(15)
        .fontColor(item.mark === 'pending' ? '#9AA0A6' : '#1F2329')
        .layoutWeight(1)
    }
    .width('100%')
    .height(48)
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column({ space: 4 }) {
      ForEach(this.stages, (item: StageItem) => {
        this.stageRow(item);
      }, (item: StageItem) => item.titleKey)
    }
    .width('100%')
    .padding(16)
    .borderRadius(12)
    .borderWidth(1)
    .borderColor('#E8EAED')
    .backgroundColor('#FFFFFF')
    .alignItems(HorizontalAlign.Start)
  }
}
