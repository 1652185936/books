/**
 * 校验报告弹窗（P-F03 主组件 `ReportDialog`，LLD §6.3「查看报告」交互）。
 *
 * 以 CustomDialog 展示应用端校验报告概览：各阶段标记、已检查/总文件数、警告数、阻断错误（若有）。
 * 报告内容由页面据 VM 状态组装传入；本组件只读渲染，不持业务状态、不触 IO。
 * **不展示**绝对路径/哈希值/完整正文（CLAUDE.md §5）。
 *
 * 未编译验证（缺 HarmonyOS SDK）：CustomDialogController/ArkUI 组件与 `$r` 资源解析以 API 12 为准。
 */
import { StageItem } from './ValidationStageGrid';
import { StageMark } from '../../viewmodels/ImportValidateVM';

/** 报告展示数据（页面据 VM 状态组装）。 */
export interface ValidationReport {
  /** 各阶段标记（标题资源键 + 标记）。 */
  stages: StageItem[];
  /** 已检查文件数。 */
  checkedFiles: number;
  /** 总文件数（-1 表示未知）。 */
  totalFiles: number;
  /** 警告累计数。 */
  warningCount: number;
  /** 阻断错误文案资源名（已转写物理键；空串表示无）。 */
  errorMessageName: string;
}

/** 标记 → 行尾状态文字资源名（通过/失败/进行/待）。 */
const MARK_LABEL_KEY: Record<string, string> = {
  done: 'import_validate_mark_done',
  failed: 'import_validate_mark_failed',
  active: 'import_validate_mark_active',
  pending: 'import_validate_mark_pending'
};

/**
 * 校验报告弹窗组件（CustomDialog）。
 */
@CustomDialog
export struct ReportDialog {
  /** 弹窗控制器（页面持有以 open/close）。 */
  controller: CustomDialogController;
  /** 报告数据。 */
  @Prop report: ValidationReport;
  /** 关闭回调（点击「关闭」时调用）。 */
  onClose: () => void = () => {};

  /**
   * 取标记对应行尾状态文字资源名。
   * @param mark 阶段标记。
   * @returns 资源名串。
   */
  private markLabelKey(mark: StageMark): string {
    // 命中键或 pending 回退
    const key: string | undefined = MARK_LABEL_KEY[mark];
    return key !== undefined ? key : MARK_LABEL_KEY.pending;
  }

  /**
   * 渲染单个阶段报告行（阶段名 + 状态文字）。
   * @param item 阶段定义。
   * @returns 无（@Builder 子树）。
   */
  @Builder
  reportRow(item: StageItem) {
    Row() {
      Text($r(`app.string.${item.titleKey}`))
        .fontSize(14)
        .fontColor('#1F2329')
        .layoutWeight(1)
      Text($r(`app.string.${this.markLabelKey(item.mark)}`))
        .fontSize(13)
        .fontColor(item.mark === 'failed' ? '#C03B3B' : (item.mark === 'done' ? '#2BA471' : '#6B7075'))
    }
    .width('100%')
    .height(36)
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column({ space: 12 }) {
      // 标题
      Text($r('app.string.import_validate_report_title'))
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor('#1F2329')

      // 各阶段标记
      Column() {
        ForEach(this.report.stages, (item: StageItem) => {
          this.reportRow(item);
        }, (item: StageItem) => item.titleKey)
      }
      .width('100%')

      Divider().color('#E8EAED')

      // 文件计数
      if (this.report.totalFiles >= 0) {
        Row() {
          Text($r('app.string.import_validate_report_files'))
            .fontSize(14)
            .fontColor('#6B7075')
            .layoutWeight(1)
          Text($r('app.string.import_validate_files_progress', this.report.checkedFiles, this.report.totalFiles))
            .fontSize(14)
            .fontColor('#1F2329')
        }
        .width('100%')
      }

      // 警告数
      Row() {
        Text($r('app.string.import_validate_report_warnings'))
          .fontSize(14)
          .fontColor('#6B7075')
          .layoutWeight(1)
        Text(`${this.report.warningCount}`)
          .fontSize(14)
          .fontColor(this.report.warningCount > 0 ? '#B8860B' : '#1F2329')
      }
      .width('100%')

      // 阻断错误（若有）
      if (this.report.errorMessageName.length > 0) {
        Row({ space: 6 }) {
          Text('!')
            .width(20)
            .height(20)
            .borderRadius(10)
            .textAlign(TextAlign.Center)
            .fontSize(13)
            .fontColor(Color.White)
            .backgroundColor('#C03B3B')
          Text($r(`app.string.${this.report.errorMessageName}`))
            .fontSize(14)
            .fontColor('#C03B3B')
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      // 关闭按钮
      Button($r('app.string.import_validate_report_close'))
        .width('100%')
        .height(48)
        .fontSize(16)
        .backgroundColor('#F2F3F5')
        .fontColor('#1F2329')
        .margin({ top: 4 })
        .onClick(() => {
          this.controller.close();
          this.onClose();
        })
    }
    .width('100%')
    .padding(20)
    .backgroundColor('#FFFFFF')
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }
}
