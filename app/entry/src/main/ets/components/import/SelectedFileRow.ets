/**
 * 已选文件行（P-F02 主组件 `SelectedFileRow`，LLD §6.2「已选择」状态）。
 *
 * 展示所选学习包的脱敏文件名与大小，并提供「重新选择」入口。
 * **严禁展示绝对路径**（§6.2 页面约束 + CLAUDE.md §5）：本组件只接收文件名与字节大小，
 * 大小经本地纯函数格式化为可读单位，绝不接收/渲染原始 URI 或目录路径。
 *
 * 纯展示组件：零 IO、零业务状态。可见文案取资源（CLAUDE.md §5）。
 *
 * 未编译验证（缺 HarmonyOS SDK）：ArkUI 组件与 `$r` 资源解析以 API 12 为准。
 */

/** 文件大小单位换算阶梯（B/KB/MB/GB）。 */
const SIZE_UNITS: string[] = ['B', 'KB', 'MB', 'GB'];
/** 单位进制（1024）。 */
const SIZE_BASE: number = 1024;

/**
 * 把字节数格式化为可读大小字符串（保留 1 位小数，非 B 单位）。纯函数，无副作用。
 * @param bytes 字节数（≥0）。
 * @returns 形如 `1.5 MB` 的可读字符串。
 */
function formatBytes(bytes: number): string {
  // 负数/0 防御：直接显示 0 B
  if (bytes <= 0) {
    return '0 B';
  }
  // 逐级降阶，定位单位下标
  let value: number = bytes;
  let unitIndex: number = 0;
  while (value >= SIZE_BASE && unitIndex < SIZE_UNITS.length - 1) {
    value = value / SIZE_BASE;
    unitIndex++;
  }
  // B 单位取整，其余保留 1 位小数
  const text: string = unitIndex === 0 ? `${Math.round(value)}` : value.toFixed(1);
  return `${text} ${SIZE_UNITS[unitIndex]}`;
}

/**
 * 已选文件行组件。
 */
@Component
export struct SelectedFileRow {
  /** 脱敏文件名（仅末段文件名，不含路径）。 */
  @Prop fileName: string;
  /** 文件字节大小。 */
  @Prop fileSize: number;
  /** 是否允许「重新选择」（复制中禁用）。 */
  @Prop canReselect: boolean = true;
  /** 点击「重新选择」回调。 */
  onReselect: () => void = () => {};

  build() {
    Row({ space: 12 }) {
      // 文件图标占位（用文字代替图标资源，避免引入新资源）
      Text('ZIP')
        .width(44)
        .height(44)
        .borderRadius(8)
        .textAlign(TextAlign.Center)
        .fontSize(13)
        .fontColor(Color.White)
        .backgroundColor('#C03B3B')

      // 文件名 + 大小（仅脱敏信息，绝不含路径）
      Column({ space: 4 }) {
        Text(this.fileName)
          .fontSize(15)
          .fontColor('#1F2329')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(formatBytes(this.fileSize))
          .fontSize(13)
          .fontColor('#6B7075')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 重新选择入口（复制中禁用）
      Button($r('app.string.import_reselect_button'))
        .height(40)
        .fontSize(14)
        .backgroundColor(Color.Transparent)
        .fontColor(this.canReselect ? '#C03B3B' : '#9AA0A6')
        .enabled(this.canReselect)
        .onClick(() => {
          if (this.canReselect) {
            this.onReselect();
          }
        })
    }
    .width('100%')
    .padding(16)
    .borderRadius(12)
    .borderWidth(1)
    .borderColor('#E8EAED')
    .backgroundColor('#FFFFFF')
    .alignItems(VerticalAlign.Center)
  }
}
