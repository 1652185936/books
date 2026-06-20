/**
 * 手写服务（F06，《04-接口与DTO契约》§5 `HandwritingService`；LLD §4.1 笔迹文件 / §3.15 三态存储 / §4.2 识别状态机）。
 *
 * 职责（页面与设备 IO/识别 SDK 的隔离层，CLAUDE.md §5 / 04 §12 规则9「笔迹采集/橡皮擦/撤销归 StrokeSession」）：
 * - `begin(target)`：新建一条空 `StrokeSession`（空 `StrokeDocument`，画布尺寸取 target 的 vp 尺寸；§4.1 同坐标系）。
 * - `persistDraft(session)`：经**注入的 `StrokeStore` 端口**把 `StrokeDocument` 落盘为草稿快照（§4.1 书写中每 2 秒
 *   快照 / 退出前强制落盘）。仿导入内核「端口 + 生产适配器在页面装配」范式：本服务纯逻辑、零 `@ohos.*` 依赖，
 *   `.stroke.json.gz` 序列化/压缩/文件写入由生产适配器承担。**停笔不自动调用识别**（§4.1 / CLAUDE.md §6）。
 * - `recognize(session)`：为满足 `implements HandwritingService`，**委托注入的 `HandwritingRecognizer` 端口**
 *   （其生产实现属 F07，本轮注入抛「未接入」AppError 的占位适配器即可）。F06 不实现识别，仅留接线点。
 *
 * 三态分存（CLAUDE.md §2.9 / §3.15）：本服务只负责**原始笔迹**（StrokeDocument）的会话与落盘；识别文本与判分
 * 结果由 F07 的 `recognized_text_json` / `blank_results_json` 独立存储，绝不用识别结果覆盖原始笔迹。
 *
 * 纯逻辑、零 ArkUI/`@ohos.*` 依赖：会话管理与笔画追加为内存操作；落盘经 `StrokeStore` 端口，
 * 识别经 `HandwritingRecognizer` 端口；二者生产适配器在页面装配处提供。可用内存假实现单测（见 `.ralph/f06-test/`）。
 */
import { Id, EpochMs, AppError } from '../domain/entities/common';
import { AppErrors } from '../utils/AppErrors';
import {
  HandwritingService, HandwritingRecognizer, HandwritingTarget, HandwritingMode,
  StrokeSession, StrokeDocument, RecognitionHandle, RecognitionResult
} from '../domain/entities/handwriting';
import { IdFactory } from './import/ContentMapper';

/** 识别未接入错误码（F07 落地前占位适配器抛出；走兜底状态文案键，不泄露内部细节）。 */
export const RECOGNITION_NOT_WIRED: string = 'RECOGNITION_NOT_WIRED';

/**
 * 笔迹落盘存储端口（§4.1）：把 `StrokeDocument` 持久化为 `.stroke.json.gz` 草稿快照并返回沙箱相对路径，
 * 供 `handwriting_records.stroke_path` 引用。生产适配器以 `@ohos.file.fs` + gzip 实现（DTO `pressure`↔文件 `p`
 * 等字段映射遵 §4.1 D7）；单测以内存假实现注入。本端口只落原始笔迹，不触碰识别文本/判分（三态分存，§3.15）。
 */
export interface StrokeStore {
  /**
   * 持久化笔迹文档为草稿快照。
   * @param session 笔迹会话（含 target 与 document）。
   * @returns 落盘后的沙箱相对路径（`.stroke.json.gz`，不含设备绝对路径，CLAUDE.md §5）。
   */
  saveDraft(session: StrokeSession): Promise<string>;
}

/**
 * 手写识别器占位适配器（F06）：F07 落地前注入此实现，`recognize` 始终返回失败句柄并抛「未接入」。
 *
 * 设计意图：让 `HandwritingService.recognize` 满足 `implements` 且页面能装配，但 F06 **绝不**触发真实识别
 * （停笔不识别、确认答案才提交，由 F07 接真实识别器；CLAUDE.md §6/§8）。失败为可重试态，便于 F07 平滑替换。
 */
export class NotWiredRecognizer implements HandwritingRecognizer {
  /**
   * 占位识别：立即返回一个已拒绝结果的句柄（不调用任何识别后端）。
   * @param input 笔迹文档（占位实现不消费）。
   * @param mode 识别模式（占位实现不消费）。
   * @returns 失败识别句柄（result 解析为 ok=false 的 RecognitionResult）。
   */
  recognize(input: StrokeDocument, mode: HandwritingMode): RecognitionHandle {
    // 请求 ID（占位常量，便于日志识别为未接入态）
    const requestId: Id = 'not-wired';
    // 失败结果（service-unavailable：F07 识别后端尚未接入；retryable=true 供 F07 替换后重试）
    const failure: RecognitionResult = {
      ok: false, requestId, errorCode: 'service-unavailable', retryable: true, durationMs: 0
    };
    return { requestId, result: Promise.resolve(failure), cancel: (): void => {} };
  }
}

/**
 * 手写服务实现（会话/草稿/识别编排）。
 */
export class HandwritingServiceImpl implements HandwritingService {
  /** 笔迹落盘存储端口（构造注入，生产适配器在页面装配）。 */
  private readonly store: StrokeStore;
  /** 手写识别器端口（构造注入；F06 注入 NotWiredRecognizer 占位，F07 替换为真实识别器）。 */
  private readonly recognizer: HandwritingRecognizer;
  /** 会话 ID 生成器（构造注入，与导入落库一致，不在服务内触 SDK）。 */
  private readonly idFactory: IdFactory;
  /** 时间源（epoch ms；构造注入便于确定性测试，缺省取系统时钟）。 */
  private readonly now: () => EpochMs;

  /**
   * @param store 笔迹落盘存储端口。
   * @param recognizer 手写识别器端口（F06 占位 NotWiredRecognizer）。
   * @param idFactory 会话 ID 生成器。
   * @param now 时间源（缺省 `() => Date.now()`）。
   */
  constructor(
    store: StrokeStore, recognizer: HandwritingRecognizer, idFactory: IdFactory, now?: () => EpochMs) {
    this.store = store;
    this.recognizer = recognizer;
    this.idFactory = idFactory;
    this.now = now !== undefined ? now : (): EpochMs => Date.now();
  }

  /**
   * 开始一条笔迹会话（空 StrokeDocument，画布取 target 的 vp 尺寸，§4.1 同坐标系）。
   * @param target 手写目标（exercise-blank / note / review-answer）。
   * @returns 新建的空笔迹会话（dirty=false）。
   */
  begin(target: HandwritingTarget): StrokeSession {
    // 空笔迹文档（format/version 固定为协议常量，画布尺寸与 blank 渲染同坐标系）
    const document: StrokeDocument = {
      format: 'ai.studybook.stroke',
      version: 1,
      canvas: { widthVp: target.canvasWidthVp, heightVp: target.canvasHeightVp },
      strokes: []
    };
    return {
      sessionId: this.idFactory.newId(),
      target,
      document,
      dirty: false,
      updatedAt: this.now()
    };
  }

  /**
   * 持久化草稿快照（经 StrokeStore 端口落盘；停笔不识别，§4.1）。落盘成功后清 dirty。
   * @param session 笔迹会话。
   * @returns 落盘完成的 Promise（失败抛 AppError，不抛裸字符串，04 §1）。
   */
  async persistDraft(session: StrokeSession): Promise<void> {
    try {
      // 经端口落盘为 .stroke.json.gz（路径供 handwriting_records.stroke_path，本服务不直接写 DB）
      await this.store.saveDraft(session);
      // 落盘成功：清脏标记并刷新更新时间（页面据此判断是否需再次快照）
      session.dirty = false;
      session.updatedAt = this.now();
    } catch (cause) {
      throw AppErrors.from(cause, 'DB_WRITE_FAILED');
    }
  }

  /**
   * 提交识别：委托注入的识别器端口。F06 注入占位识别器（始终失败），F07 替换为真实识别器。
   * **仅在用户点击「确认答案」后由 VM 调用**，绝不在停笔时自动调用（§4.1 / CLAUDE.md §6/§8）。
   * @param session 笔迹会话。
   * @returns 可取消的识别句柄。
   */
  recognize(session: StrokeSession): RecognitionHandle {
    // 委托识别器端口（输入为原始笔迹文档与识别模式；F07 在此接真实识别）
    return this.recognizer.recognize(session.document, session.target.mode);
  }
}

/**
 * 构造识别未接入领域错误（供 F07 落地前的页面/VM 在尝试识别时统一兜底文案，可转 AppError，04 §1）。
 * @returns 标记为可重试的「识别未接入」AppError（走兜底状态文案键）。
 */
export function recognitionNotWiredError(): AppError {
  return AppErrors.create(RECOGNITION_NOT_WIRED, { retryable: true, detail: 'recognition-not-wired(F07)' });
}
