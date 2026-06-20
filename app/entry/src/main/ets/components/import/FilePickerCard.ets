/**
 * 文件选择卡片（P-F02 主组件 `FilePickerCard`，LLD §6.2「选择文件」）。
 *
 * 居中的「选择学习包」入口卡片：一个大号主操作按钮（手写主操作 ≥56vp，触控目标约束 §6）。
 * 实际系统文件选择（`DocumentViewPicker`）由页面发起，本组件只暴露 `onPick` 回调与禁用态，
 * 自身零 IO、零业务状态。可见文案全部取资源（CLAUDE.md §5）。
 *
 * 未编译验证（缺 HarmonyOS SDK）：ArkUI 组件与 `$r` 资源解析以 API 12 为准。
 */

/**
 * 文件选择卡片组件。
 */
@Component
export struct FilePickerCard {
  /** 点击「选择文件」回调（由页面发起 DocumentViewPicker）。 */
  onPick: () => void = () => {};
  /** 是否禁用（复制中防重复点击时禁用，§6.2）。 */
  @Prop disabled: boolean = false;

  build() {
    Column({ space: 16 }) {
      // 提示标题
      Text($r('app.string.import_pick_title'))
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor('#1F2329')
      // 辅助说明（仅支持 .studybook.zip）
      Text($r('app.string.import_pick_hint'))
        .fontSize(14)
        .fontColor('#6B7075')
        .textAlign(TextAlign.Center)
      // 主操作：选择文件（手写主操作 ≥56vp）
      Button($r('app.string.import_pick_button'))
        .width(220)
        .height(56)
        .fontSize(17)
        .backgroundColor(this.disabled ? '#E8AAAA' : '#C03B3B')
        .fontColor(Color.White)
        .enabled(!this.disabled)
        .onClick(() => {
          // 禁用态不响应（双重保险，避免复制中重复触发）
          if (!this.disabled) {
            this.onPick();
          }
        })
    }
    .width('100%')
    .padding(32)
    .borderRadius(16)
    .borderWidth(1)
    .borderColor('#E8EAED')
    .backgroundColor('#FFFFFF')
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }
}
