/**
 * 校验结果摘要（P-F03 主组件 `ValidationSummary`，LLD §6.3）。
 *
 * 顶部状态横幅：按当前态（校验中/可导入/警告/失败/导入中/完成）展示进度条、状态文案与计数（已检查/总文件、警告数）。
 * 阻断错误据 `messageKey` 渲染对应资源文案（§3.14A 桥接，物理键转写在页面层完成后传入）。
 *
 * 纯展示组件：零 IO、零业务状态。可见文案取资源（CLAUDE.md §5），不在组件内硬编码；不展示绝对路径/哈希值。
 *
 * 未编译验证（缺 HarmonyOS SDK）：ArkUI 组件与 `$r` 资源解析以 API 12 为准。
 */
import { ImportValidateStatus } from '../../viewmodels/ImportValidateVM';

/** 状态 → 横幅主色（绿=完成/可导入、琥珀=警告、红=失败、品牌红=进行）。 */
const STATUS_COLOR: Record<string, string> = {
  validating: '#C03B3B',
  importable: '#2BA471',
  warning: '#E6A23C',
  failed: '#C03B3B',
  importing: '#C03B3B',
  completed: '#2BA471'
};

/** 状态 → 标题资源名（element/string.json，由本 feature 申报）。 */
const STATUS_TITLE_KEY: Record<string, string> = {
  validating: 'import_validate_status_validating',
  importable: 'import_validate_status_importable',
  warning: 'import_validate_status_warning',
  failed: 'import_validate_status_failed',
  importing: 'import_validate_status_importing',
  completed: 'import_validate_status_completed'
};

/**
 * 校验结果摘要组件。
 */
@Component
export struct ValidationSummary {
  /** 当前有限状态。 */
  @Prop status: ImportValidateStatus;
  /** 整体进度（0..1）。 */
  @Prop progress: number;
  /** 警告累计数（IMP-015）。 */
  @Prop warningCount: number;
  /** 已检查文件数。 */
  @Prop checkedFiles: number;
  /** 总文件数（-1 表示未知）。 */
  @Prop totalFiles: number;
  /** 阻断错误文案资源名（已由页面经 §3.14A 物理键转写；空串表示无错误）。 */
  @Prop errorMessageName: string;
  /** 阻断错误是否可重试（决定提示色：琥珀可重试 / 红终态拒绝）。 */
  @Prop errorRetryable: boolean;

  /**
   * 取当前状态横幅主色。
   * @returns 颜色串。
   */
  private statusColor(): string {
    // 命中色或品牌红回退
    const color: string | undefined = STATUS_COLOR[this.status as string];
    return color !== undefined ? color : '#C03B3B';
  }

  /**
   * 取当前状态标题资源名。
   * @returns 资源名串。
   */
  private statusTitleKey(): string {
    // 命中键或校验中回退
    const key: string | undefined = STATUS_TITLE_KEY[this.status as string];
    return key !== undefined ? key : STATUS_TITLE_KEY.validating;
  }

  build() {
    Column({ space: 10 }) {
      // 状态标题
      Text($r(`app.string.${this.statusTitleKey()}`))
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.statusColor())

      // 进度条（0..1）
      Progress({ value: Math.round(this.progress * 100), total: 100, type: ProgressType.Linear })
        .color(this.statusColor())
        .width('100%')
        .height(8)

      // 文件计数（已检查 / 总数；总数未知时仅展示已检查）
      if (this.totalFiles >= 0) {
        Text($r('app.string.import_validate_files_progress', this.checkedFiles, this.totalFiles))
          .fontSize(13)
          .fontColor('#6B7075')
      }

      // 警告提示（IMP-015 非阻断，琥珀色）
      if (this.warningCount > 0 && this.status !== ImportValidateStatus.Failed) {
        Row({ space: 6 }) {
          Text('!')
            .width(20)
            .height(20)
            .borderRadius(10)
            .textAlign(TextAlign.Center)
            .fontSize(13)
            .fontColor(Color.White)
            .backgroundColor('#E6A23C')
          Text($r('app.string.import_validate_warning_hint', this.warningCount))
            .fontSize(14)
            .fontColor('#B8860B')
        }
        .alignItems(VerticalAlign.Center)
      }

      // 阻断错误提示（据 messageKey 渲染；可重试琥珀、终态拒绝红）
      if (this.errorMessageName.length > 0) {
        Row({ space: 6 }) {
          Text('!')
            .width(20)
            .height(20)
            .borderRadius(10)
            .textAlign(TextAlign.Center)
            .fontSize(13)
            .fontColor(Color.White)
            .backgroundColor(this.errorRetryable ? '#E6A23C' : '#C03B3B')
          Text($r(`app.string.${this.errorMessageName}`))
            .fontSize(14)
            .fontColor(this.errorRetryable ? '#B8860B' : '#C03B3B')
            .layoutWeight(1)
        }
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .padding(16)
    .borderRadius(12)
    .backgroundColor('#F7F8FA')
    .alignItems(HorizontalAlign.Start)
  }
}
