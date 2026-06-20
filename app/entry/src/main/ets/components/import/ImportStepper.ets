/**
 * 导入步骤指示器（P-F02 主组件 `ImportStepper`，LLD §6.2「选择文件 → 预检查 → 开始校验」）。
 *
 * 横向三步条，标示导入选择页的整体流程位置。纯展示组件：仅依赖外部传入的当前步序号，
 * 不持业务状态、不触发 IO。所有可见文案取自资源文件（CLAUDE.md §5），不在组件内硬编码。
 *
 * 未编译验证（缺 HarmonyOS SDK）：ArkUI 组件与 `$r` 资源解析以 API 12 为准。
 */

/** 导入流程步骤序号（与 §6.2 三步对应）。 */
export enum ImportStep {
  /** 第 1 步：选择文件。 */
  Pick = 0,
  /** 第 2 步：预检查（类型/空间）。 */
  Precheck = 1,
  /** 第 3 步：开始校验。 */
  Validate = 2
}

/** 单步定义：序号 + 标题资源键。 */
interface StepDef {
  /** 步骤序号。 */
  index: number;
  /** 标题字符串资源（element/string.json）。 */
  title: ResourceStr;
}

/**
 * 导入步骤指示器组件。
 */
@Component
export struct ImportStepper {
  /** 当前激活步骤序号（0..2；<0 视为未开始，全部置灰）。 */
  @Prop current: number;

  /** 三步定义（标题取资源，集中声明便于一致渲染）。 */
  private readonly steps: StepDef[] = [
    { index: ImportStep.Pick, title: $r('app.string.import_step_pick') },
    { index: ImportStep.Precheck, title: $r('app.string.import_step_precheck') },
    { index: ImportStep.Validate, title: $r('app.string.import_step_validate') }
  ];

  /**
   * 渲染单个步骤圆点与标题。
   * @param step 步骤定义。
   * @param isLast 是否末步（末步不画右侧连接线）。
   * @returns 无（@Builder 子树）。
   */
  @Builder
  stepItem(step: StepDef, isLast: boolean) {
    Row() {
      Column({ space: 6 }) {
        // 步骤圆点：已到达/激活用品牌强调，未到达置灰（红色仅作主操作/强调，UI 约束 §6）
        Text(`${step.index + 1}`)
          .width(28)
          .height(28)
          .borderRadius(14)
          .textAlign(TextAlign.Center)
          .fontSize(14)
          .fontColor(this.current >= step.index ? Color.White : '#9AA0A6')
          .backgroundColor(this.current >= step.index ? '#C03B3B' : '#E8EAED')
        // 步骤标题
        Text(step.title)
          .fontSize(13)
          .fontColor(this.current >= step.index ? '#1F2329' : '#9AA0A6')
      }
      .alignItems(HorizontalAlign.Center)

      // 连接线（末步省略）
      if (!isLast) {
        Divider()
          .vertical(false)
          .strokeWidth(2)
          .color(this.current > step.index ? '#C03B3B' : '#E8EAED')
          .width(40)
          .margin({ left: 8, right: 8 })
      }
    }
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Row() {
      ForEach(this.steps, (step: StepDef) => {
        this.stepItem(step, step.index === this.steps.length - 1);
      }, (step: StepDef) => `${step.index}`)
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .padding({ top: 16, bottom: 16 })
  }
}
