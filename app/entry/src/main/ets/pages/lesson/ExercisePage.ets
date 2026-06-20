/**
 * P-F06 手写练习页（route_map.json → `exercise`，LLD §6.6）。
 *
 * 装配图：ExercisePage
 *   → ExerciseRepositoryImpl（getExercise/createDraft/saveGrade，经 DB）
 *   → HandwritingServiceImpl（begin/persistDraft，StrokeStore 端口 + NotWiredRecognizer 占位）
 *   → ExerciseVM（状态机；load/appendStroke/undo/redo/clear/persistDrafts/confirm）
 *   → SegmentedPrompt（题面展示）
 *   → HandwritingBlank（逐空 Canvas 手写区，含即时墨迹，§6 「书写墨迹必须即时显示」）
 *   → NotWiredConfirmHandler（F07 接口占位，CLAUDE.md §2-11 保留接线点）
 *
 * 交互约束（CLAUDE.md §6 / LLD §6.6）：
 * - 停笔不触发识别；只有点击「确认答案」后才提交（§4.1 / CLAUDE.md §6/§8）。
 * - 正常流不展示识别文本/置信度/候选词（§4.1）。
 * - 章节/练习切换经返回按钮，**禁止左右滑动**（§2.6 / CLAUDE.md §2.6）。
 * - 手写横线有效高度 ≥88vp（§6.6 / CLAUDE.md §6）。
 * - 触控目标 ≥48vp，手写主操作（确认答案）≥56vp（CLAUDE.md §6）。
 *
 * 草稿自动保存：每 2 秒对脏会话调用 persistDrafts；退出前强制落盘（§4.1 / R-021）。
 *
 * 非手写四种题型（choice/true-false/match/order-words）：导入后保留、占位展示；
 * 作答交互列入后续迭代，绝不砍除或静默丢弃（R-063 / CLAUDE.md §2-11）。
 *
 * 未编译验证（缺 HarmonyOS SDK）：
 * - ArkUI Canvas/TouchEvent/setInterval 以 API 12 为准，真机待实测。
 * - StrokeStore.saveDraft 生产实现需 @ohos.file.fs + gzip（本版 NoopStrokeStore 保持内存态）。
 * - UuidIdFactory 依赖 util.generateRandomUUID（SDK 运行时提供）。
 */
import { common } from '@kit.AbilityKit';
import { NavPathStack } from '@kit.ArkUI';
import { ExerciseParams, normalizeExerciseFrom } from '../../utils/Routes';
import { Database } from '../../database/Database';
import { ExerciseRepositoryImpl } from '../../repositories/ExerciseRepository';
import { HandwritingServiceImpl, NotWiredRecognizer, StrokeStore } from '../../services/HandwritingService';
import { ExerciseVM, ExerciseStatus, BlankAttempt, ExerciseConfirmPayload, ConfirmHandler } from '../../viewmodels/ExerciseVM';
import { ExerciseTokens } from '../../components/exercise/ExerciseTokens';
import { SegmentedPrompt } from '../../components/exercise/SegmentedPrompt';
import { ExerciseDetail, ExerciseType } from '../../domain/entities/exercise';
import { Id, EpochMs } from '../../domain/entities/common';
import { HandwritingTarget, StrokeSession, Stroke, StrokePoint, StrokeDocument } from '../../domain/entities/handwriting';
import { UuidIdFactory } from '../../utils/UuidIdFactory';
import { IdFactory } from '../../services/import/ContentMapper';

/** 五种手写题型（F06 主流程作答）。 */
const HANDWRITING_TYPES: ExerciseType[] = [
  'fill-blank-handwriting', 'multi-blank-handwriting', 'rewrite-sentence-handwriting',
  'short-answer-handwriting', 'correction-handwriting'
];

/**
 * NoopStrokeStore：草稿落盘存储端口的空操作实现（F06；§4.1 落盘到 .stroke.json.gz 需 @ohos.file.fs + gzip）。
 * 本版保持笔迹于内存会话；生产实现在 F07/P3 阶段用 @ohos.file.fs 替换本类。
 * persistDraft 调用 saveDraft，失败不会抛出（VM 捕获并设 state.error）。
 */
class NoopStrokeStore implements StrokeStore {
  /**
   * 占位落盘（内存态；正式 .stroke.json.gz 生产实现属 F07/P3）。
   * @param session 笔迹会话（不消费）。
   * @returns 空路径（无实际文件写入）。
   */
  async saveDraft(_session: StrokeSession): Promise<string> {
    return '';
  }
}

/**
 * F06 占位确认处理器（F07 识别 + 判分编排的接线点）。
 * F06 阶段确认后状态机切 'recognizing' 并立即解析（无实际识别）；
 * F07 落地时替换本类为真实 HandwritingService.recognize + GradingService 流程。
 */
class NotWiredConfirmHandler implements ConfirmHandler {
  /**
   * 占位：将 payload 交给 F07 的识别/判分编排（F06 阶段为空实现）。
   * @param payload 提交载体（含逐空笔迹引用）。
   * @returns 完成的 Promise（F06 立即 resolve，不调用识别后端）。
   */
  async handle(_payload: ExerciseConfirmPayload): Promise<void> {
    // F07 接：HandwritingService.recognize + GradingService.grade + ExerciseRepository.saveGrade
    // F06 阶段：不识别、不判分、不落库 grade 结果（保留接线点，按 R-063/CLAUDE.md §2-11）
  }
}

/**
 * P-F06/P-F07 手写练习与识别判分页路由构建函数（route_map.json → `exercise`，LLD §6.6/§6.7）。
 * @returns 无（构建 NavDestination）
 */
@Builder
export function ExercisePageBuilder(): void {
  ExercisePage();
}

/**
 * 逐空手写画布组件（F06，LLD §6.6）。
 *
 * 功能：即时墨迹（停笔不识别，§4.1）、激活态红色边框（§6.6「当前 blank 使用强调边框」）、
 * 笔画在 onTouch 期间实时绘制（CLAUDE.md §6「书写墨迹必须即时显示」），
 * 停笔时把完整笔画交给 onStroke 回调（VM 通过 appendStroke 追加）。
 */
@Component
struct HandwritingBlank {
  /** 该空运行态（widthVp/heightVp/session/blank）。 */
  @Prop attempt: BlankAttempt;
  /** 是否为当前激活空（激活态强调边框，§6.6）。 */
  @Prop isActive: boolean;
  /** 笔迹版本号（父页面变更时 @Watch 驱动重绘；每次 appendStroke/undo/redo/clear 后递增）。 */
  @Prop version: number;
  /** 点击或触摸时聚焦（父页面调用 vm.focusBlank）。 */
  onFocus: () => void = () => {
  };
  /** 笔画完成时回调（父页面调用 vm.appendStroke）。 */
  onStroke: (stroke: Stroke) => void = (_s: Stroke) => {
  };

  /** Canvas 渲染上下文（抗锯齿）。 */
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  /** 当前进行中（未落笔完成）的笔画采样点序列（即时显示用）。 */
  private inProgressPoints: StrokePoint[] = [];
  /** 笔触开始时间（用于采样点相对时间戳计算）。 */
  private touchStartMs: number = 0;
  /** 该空内部笔画序号（生成唯一 strokeId，格式 sessionId-seq）。 */
  private strokeSeq: number = 0;

  /**
   * 监听版本号变化，触发完整重绘（undo/redo/clear/appendStroke 后由父页面递增 version）。
   */
  @Watch('version')
  onVersionChange(): void {
    this.redrawAll();
  }

  /**
   * 全量重绘：清空 → 横线导向背景 → 已提交笔迹 → 进行中笔迹（即时显示）。
   */
  private redrawAll(): void {
    this.ctx.clearRect(0, 0, this.attempt.widthVp, this.attempt.heightVp);
    this.drawGuideLines();
    const strokes: Stroke[] = this.attempt.session.document.strokes;
    for (let i: number = 0; i < strokes.length; i++) {
      this.drawPoints(strokes[i].points);
    }
    if (this.inProgressPoints.length > 1) {
      this.drawPoints(this.inProgressPoints);
    }
  }

  /**
   * 绘制手写横线导向（按 blank.lines 分等间距，CLAUDE.md §6 ≥88vp 有效高度）。
   */
  private drawGuideLines(): void {
    const lineCount: number = this.attempt.blank.lines;
    if (lineCount <= 0) {
      return;
    }
    this.ctx.strokeStyle = '#D8D8D8';
    this.ctx.lineWidth = 0.5;
    for (let i: number = 1; i <= lineCount; i++) {
      const y: number = (i * this.attempt.heightVp) / (lineCount + 1);
      this.ctx.beginPath();
      this.ctx.moveTo(0, y);
      this.ctx.lineTo(this.attempt.widthVp, y);
      this.ctx.stroke();
    }
  }

  /**
   * 绘制采样点序列为平滑折线（钢笔颜色/宽度取 ExerciseTokens 常量）。
   * @param points 采样点序列（至少 2 点才绘制）。
   */
  private drawPoints(points: StrokePoint[]): void {
    if (points.length < 2) {
      return;
    }
    this.ctx.beginPath();
    this.ctx.strokeStyle = ExerciseTokens.PEN_COLOR;
    this.ctx.lineWidth = ExerciseTokens.PEN_WIDTH;
    this.ctx.lineCap = 'round';
    this.ctx.lineJoin = 'round';
    this.ctx.moveTo(points[0].x, points[0].y);
    for (let i: number = 1; i < points.length; i++) {
      this.ctx.lineTo(points[i].x, points[i].y);
    }
    this.ctx.stroke();
  }

  /**
   * 触摸/笔事件处理：即时绘制墨迹，停笔时回调 onStroke（绝不自动触发识别，§4.1）。
   * @param e 触摸事件。
   */
  private handleTouch(e: TouchEvent): void {
    if (!this.isActive) {
      this.onFocus();
    }
    if (e.type === TouchType.Down) {
      this.touchStartMs = Date.now();
      const t: TouchObject = e.touches[0];
      this.inProgressPoints = [{
        x: t.x, y: t.y, t: 0, pressure: t.force, tiltX: 0, tiltY: 0
      }];
    } else if (e.type === TouchType.Move) {
      const t: TouchObject = e.touches[0];
      this.inProgressPoints.push({
        x: t.x, y: t.y, t: Date.now() - this.touchStartMs, pressure: t.force, tiltX: 0, tiltY: 0
      });
      // 即时显示：每次 Move 重绘（包含进行中笔迹）
      this.redrawAll();
    } else if (e.type === TouchType.Up) {
      if (this.inProgressPoints.length > 0) {
        const t: TouchObject = e.changedTouches[0];
        this.inProgressPoints.push({
          x: t.x, y: t.y, t: Date.now() - this.touchStartMs, pressure: 0, tiltX: 0, tiltY: 0
        });
        this.strokeSeq = this.strokeSeq + 1;
        const stroke: Stroke = {
          id: `${this.attempt.session.sessionId}-${this.strokeSeq}`,
          points: [...this.inProgressPoints]
        };
        this.inProgressPoints = [];
        // 完成笔画：交给父页面的 vm.appendStroke（停笔不识别，§4.1）
        this.onStroke(stroke);
      }
    }
  }

  build() {
    Stack() {
      Canvas(this.ctx)
        .width(this.attempt.widthVp)
        .height(this.attempt.heightVp)
        .onReady(() => {
          this.redrawAll();
        })
        .onTouch((e: TouchEvent) => {
          this.handleTouch(e);
        })
        .backgroundColor(Color.White)
    }
    .width(this.attempt.widthVp)
    .height(this.attempt.heightVp)
    .border({
      width: 2,
      color: this.isActive ? ExerciseTokens.BLANK_ACTIVE_BORDER : ExerciseTokens.BLANK_BORDER,
      radius: 4
    })
  }
}

/**
 * P-F06/P-F07 手写练习与识别判分页（LLD §6.6/§6.7）。
 *
 * 状态机（由 ExerciseVM 承载）：loading → blank → submittable → recognizing → (F07 判分结果)
 *                               loading → broken（练习损坏）
 *
 * 页面快照同步：ExerciseVM 为 @Observed 类；页面以 @State 镜像 status/activeBlankIndex/strokeVersion
 * 确保异步态变更稳定驱动重渲染（不依赖 @Observed 深层观测的版本差异）。
 */
@Component
export struct ExercisePage {
  /** 顶层练习状态快照（镜像 vm.status）。 */
  @State status: ExerciseStatus = 'loading';
  /** 当前激活空下标快照（镜像 vm.activeBlankIndex）。 */
  @State activeBlankIndex: number = -1;
  /** 笔迹版本号（每次 appendStroke/undo/redo/clear 后递增，驱动 HandwritingBlank 重绘）。 */
  @State strokeVersion: number = 0;
  /** 练习详情快照（镜像 vm.detail；用于 SegmentedPrompt 和非手写占位判断）。 */
  @State detail?: ExerciseDetail = undefined;
  /** 错误快照（镜像 vm.error；用于 broken 态文案）。 */
  @State hasError: boolean = false;

  /** NavPathStack（返回用）。 */
  private pathStack?: NavPathStack = undefined;
  /** 进入来源（'chapter' | 'wrongbook'，决定返回栈，§6.13）。 */
  private from: string = 'chapter';
  /** 练习 ViewModel（装配并持有）。 */
  private vm?: ExerciseVM = undefined;
  /** 自动保存定时器 ID（every 2s persist dirty drafts，§4.1）。 */
  private autosaveTimer: number = -1;

  /**
   * 页面初始化（NavDestination.onReady 调用）：装配所有依赖 → 加载练习。
   * @param params 路由参数（bookId/chapterId/exerciseId/from?）。
   * @param stack NavPathStack（返回用）。
   * @returns 完成的 Promise。
   */
  private async init(params: ExerciseParams, stack: NavPathStack): Promise<void> {
    this.pathStack = stack;
    this.from = normalizeExerciseFrom(params.from);
    const appContext: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const database: Database = await Database.open(appContext);
    const idFactory: IdFactory = new UuidIdFactory();
    const repo: ExerciseRepositoryImpl = new ExerciseRepositoryImpl(database, idFactory);
    const store: NoopStrokeStore = new NoopStrokeStore();
    const recognizer: NotWiredRecognizer = new NotWiredRecognizer();
    const handwriting: HandwritingServiceImpl = new HandwritingServiceImpl(store, recognizer, idFactory);
    const handler: NotWiredConfirmHandler = new NotWiredConfirmHandler();
    const vm: ExerciseVM = new ExerciseVM(repo, handwriting, handler);
    this.vm = vm;
    // 加载练习（状态机由 VM 推进）
    await vm.load(params.exerciseId);
    this.syncFromVm();
    // 自动保存定时器（每 2 秒落盘脏会话，§4.1）
    this.autosaveTimer = setInterval((): void => {
      if (this.vm !== undefined) {
        this.vm.persistDrafts().catch((): void => {
          this.syncFromVm();
        });
      }
    }, 2000);
  }

  /**
   * 把 VM 状态同步到页面 @State（确保异步变更触发重渲染）。
   */
  private syncFromVm(): void {
    if (this.vm === undefined) {
      return;
    }
    this.status = this.vm.status;
    this.activeBlankIndex = this.vm.activeBlankIndex;
    this.detail = this.vm.detail;
    this.hasError = this.vm.error !== undefined;
  }

  /**
   * 执行 VM 笔迹操作并同步状态 + 递增版本号（触发 HandwritingBlank 重绘）。
   * @param action 操作函数（vm.undo / vm.redo / vm.clear 等）。
   */
  private doStrokeAction(action: () => boolean): void {
    if (this.vm === undefined) {
      return;
    }
    const changed: boolean = action();
    if (changed) {
      this.strokeVersion = this.strokeVersion + 1;
      this.syncFromVm();
    }
  }

  /**
   * 添加笔画到当前激活空（HandwritingBlank.onStroke 回调）。
   * @param blankIndex 空下标（确保笔画归属正确，防跨空）。
   * @param stroke 完整笔画。
   */
  private appendStroke(blankIndex: number, stroke: Stroke): void {
    if (this.vm === undefined) {
      return;
    }
    // 确保当前激活空为指定空（触摸命中测试，防止跨空）
    if (this.vm.activeBlankIndex !== blankIndex) {
      this.vm.focusBlank(blankIndex);
    }
    const ok: boolean = this.vm.appendStroke(stroke);
    if (ok) {
      this.strokeVersion = this.strokeVersion + 1;
      this.syncFromVm();
    }
  }

  /**
   * 「确认答案」：强制落盘 → 切 recognizing → 调用 handler（F07 接识别判分）。
   */
  private async confirmAnswer(): Promise<void> {
    if (this.vm === undefined) {
      return;
    }
    await this.vm.confirm();
    this.syncFromVm();
  }

  /**
   * 当前题型是否为五种手写题型之一（false = 非手写占位，§2-11 保留展示）。
   */
  private isHandwritingExercise(): boolean {
    if (this.detail === undefined) {
      return false;
    }
    return HANDWRITING_TYPES.indexOf(this.detail.type) >= 0;
  }

  aboutToDisappear(): void {
    // 停止自动保存定时器
    if (this.autosaveTimer >= 0) {
      clearInterval(this.autosaveTimer);
      this.autosaveTimer = -1;
    }
    // 退出前强制落盘（§4.1 R-021）
    if (this.vm !== undefined) {
      this.vm.persistDrafts().catch((): void => {});
    }
  }

  build() {
    NavDestination() {
      Column() {
        // ===== 主体内容 =====
        if (this.status === 'loading') {
          // 加载态
          Row() {
            LoadingProgress()
              .width(40)
              .height(40)
              .color(ExerciseTokens.BRAND_RED)
            Text($r('app.string.state_loading'))
              .fontSize(ExerciseTokens.FONT_BODY)
              .fontColor(ExerciseTokens.INK_SECONDARY)
              .margin({ left: 12 })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .layoutWeight(1)
        } else if (this.status === 'broken') {
          // 损坏态
          Column({ space: 12 }) {
            Text($r('app.string.exercise_broken'))
              .fontSize(ExerciseTokens.FONT_BODY)
              .fontColor(ExerciseTokens.WARN_AMBER)
              .textAlign(TextAlign.Center)
            Button($r('app.string.action_retry'))
              .height(ExerciseTokens.TOUCH_MIN)
              .onClick((): void => {
                if (this.pathStack !== undefined) {
                  this.pathStack.pop();
                }
              })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .padding(ExerciseTokens.PAGE_PADDING)
        } else {
          // 正常/可提交/识别中 态：显示题面 + 手写区
          Scroll() {
            Column({ space: ExerciseTokens.BLOCK_GAP }) {
              // 题面
              if (this.detail !== undefined) {
                SegmentedPrompt({ detail: this.detail })
                  .width('100%')
              }

              // 手写区（五种手写题型）或 非手写占位
              if (this.isHandwritingExercise() && this.vm !== undefined) {
                Column({ space: 16 }) {
                  ForEach(this.vm.blanks, (attempt: BlankAttempt, index: number) => {
                    Column({ space: 8 }) {
                      // 多空时显示空序号（下标从 1 开始）
                      if (this.vm !== undefined && this.vm.blanks.length > 1) {
                        Text(`${index + 1}`)
                          .fontSize(ExerciseTokens.FONT_CAPTION)
                          .fontColor(ExerciseTokens.INK_SECONDARY)
                      }
                      HandwritingBlank({
                        attempt: attempt,
                        isActive: index === this.activeBlankIndex,
                        version: this.strokeVersion,
                        onFocus: (): void => {
                          if (this.vm !== undefined) {
                            this.vm.focusBlank(index);
                            this.syncFromVm();
                          }
                        },
                        onStroke: (stroke: Stroke): void => {
                          this.appendStroke(index, stroke);
                        }
                      })
                    }
                    .alignItems(HorizontalAlign.Start)
                  })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
              } else {
                // 非手写题型占位（R-063：保留题目并提示后续迭代实现）
                Text($r('app.string.exercise_nonhandwriting'))
                  .fontSize(ExerciseTokens.FONT_BODY)
                  .fontColor(ExerciseTokens.INK_SECONDARY)
                  .textAlign(TextAlign.Center)
                  .width('100%')
                  .padding({ top: 32, bottom: 32 })
                  .backgroundColor(ExerciseTokens.SURFACE)
                  .borderRadius(8)
              }

              // 识别判分中提示横幅（status='recognizing'）
              if (this.status === 'recognizing') {
                Row({ space: 12 }) {
                  LoadingProgress()
                    .width(24)
                    .height(24)
                    .color(ExerciseTokens.BRAND_RED)
                  Text($r('app.string.exercise_recognizing'))
                    .fontSize(ExerciseTokens.FONT_BODY)
                    .fontColor(ExerciseTokens.INK_SECONDARY)
                }
                .width('100%')
                .padding(16)
                .backgroundColor(ExerciseTokens.SURFACE)
                .borderRadius(8)
              }
            }
            .padding({
              top: ExerciseTokens.PAGE_PADDING,
              bottom: ExerciseTokens.PAGE_PADDING,
              left: ExerciseTokens.PAGE_PADDING,
              right: ExerciseTokens.PAGE_PADDING
            })
            .width('100%')
          }
          .layoutWeight(1)
          .scrollBar(BarState.Auto)

          // ===== 底部工具栏（笔工具 + 确认答案）=====
          Column() {
            Divider().strokeWidth(0.5).color(ExerciseTokens.BORDER)

            // 笔迹工具栏（撤销/重做/清除，手写主操作 ≥56vp，CLAUDE.md §6）
            if (this.isHandwritingExercise()) {
              Row({ space: 8 }) {
                Button($r('app.string.exercise_undo'))
                  .height(ExerciseTokens.TOUCH_HANDWRITING_MIN)
                  .layoutWeight(1)
                  .backgroundColor(ExerciseTokens.SURFACE)
                  .fontColor(ExerciseTokens.INK)
                  .onClick((): void => {
                    this.doStrokeAction((): boolean => {
                      return this.vm !== undefined && this.vm.undo();
                    });
                  })
                Button($r('app.string.exercise_redo'))
                  .height(ExerciseTokens.TOUCH_HANDWRITING_MIN)
                  .layoutWeight(1)
                  .backgroundColor(ExerciseTokens.SURFACE)
                  .fontColor(ExerciseTokens.INK)
                  .onClick((): void => {
                    this.doStrokeAction((): boolean => {
                      return this.vm !== undefined && this.vm.redo();
                    });
                  })
                Button($r('app.string.exercise_clear'))
                  .height(ExerciseTokens.TOUCH_HANDWRITING_MIN)
                  .layoutWeight(1)
                  .backgroundColor(ExerciseTokens.SURFACE)
                  .fontColor(ExerciseTokens.INK)
                  .onClick((): void => {
                    this.doStrokeAction((): boolean => {
                      return this.vm !== undefined && this.vm.clear();
                    });
                  })
              }
              .padding({ top: 8, bottom: 8, left: ExerciseTokens.PAGE_PADDING, right: ExerciseTokens.PAGE_PADDING })
              .width('100%')
            }

            // 确认答案按钮（≥56vp，品牌红，CLAUDE.md §6；仅 submittable 态启用）
            Button($r('app.string.action_confirm'))
              .width('100%')
              .height(ExerciseTokens.TOUCH_HANDWRITING_MIN)
              .margin({
                left: ExerciseTokens.PAGE_PADDING,
                right: ExerciseTokens.PAGE_PADDING,
                bottom: ExerciseTokens.PAGE_PADDING
              })
              .backgroundColor(ExerciseTokens.BRAND_RED)
              .fontColor(Color.White)
              .enabled(this.status === 'submittable')
              .opacity(this.status === 'submittable' ? 1.0 : 0.4)
              .onClick((): void => {
                this.confirmAnswer();
              })
          }
          .width('100%')
          .backgroundColor(Color.White)
        }
      }
      .width('100%')
      .height('100%')
    }
    .title($r('app.string.route_title_exercise'))
    .onReady((ctx: NavDestinationContext) => {
      const params: ExerciseParams = ctx.pathInfo.param as ExerciseParams;
      this.init(params, ctx.pathStack).catch((): void => {
        this.status = 'broken';
        this.hasError = true;
      });
    })
  }
}
