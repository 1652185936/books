/**
 * 手写与识别 DTO 契约（《04-接口与DTO契约》§5）。
 * 适配 ArkTS：StrokeDocument.canvas 内联对象拆为 StrokeCanvas；RecognitionResult 联合两支拆为
 * RecognitionSuccess / RecognitionFailure 具名接口，字段集与判别字段 ok 不变。
 * 约束：原始笔迹必须保留，识别文本与判分结果分存；正常流程不展示识别文本/置信度/候选词（CLAUDE.md §2/§6）。
 */
import { Id, EpochMs } from './common';

/** 手写识别模式。 */
export type HandwritingMode = 'english' | 'number' | 'mixed';

/** 笔迹采样点（坐标单位 vp，LLD §1.3 R-035）。 */
export interface StrokePoint {
  /** X 坐标（vp）。 */
  x: number;
  /** Y 坐标（vp）。 */
  y: number;
  /** 相对时间戳（毫秒）。 */
  t: number;
  /** 压力 0..1。 */
  pressure: number;
  /** 笔倾角 X。 */
  tiltX: number;
  /** 笔倾角 Y。 */
  tiltY: number;
}

/** 单笔笔画。 */
export interface Stroke {
  /** 笔画 ID。 */
  id: Id;
  /** 采样点序列。 */
  points: StrokePoint[];
}

/** 笔迹画布尺寸（单位 vp，与 blank 渲染同坐标系）。 */
export interface StrokeCanvas {
  /** 画布宽（vp）。 */
  widthVp: number;
  /** 画布高（vp）。 */
  heightVp: number;
}

/** 笔迹文档（持久化格式，LLD §4.1）。 */
export interface StrokeDocument {
  /** 格式标识。 */
  format: 'ai.studybook.stroke';
  /** 格式版本。 */
  version: 1;
  /** 画布尺寸。 */
  canvas: StrokeCanvas;
  /** 笔画列表。 */
  strokes: Stroke[];
}

/** 手写目标上下文。 */
export interface HandwritingTarget {
  /** 目标类型。 */
  type: 'exercise-blank' | 'note' | 'review-answer';
  /** 归属对象 ID（练习/批注/复习卡）。 */
  ownerId: Id;
  /** 练习空位键（type='exercise-blank' 时）。 */
  blankKey?: string;
  /** 识别模式。 */
  mode: HandwritingMode;
  /** 画布宽（vp）。 */
  canvasWidthVp: number;
  /** 画布高（vp）。 */
  canvasHeightVp: number;
}

/** 笔迹会话（内存态，dirty 标记是否需落盘）。 */
export interface StrokeSession {
  /** 会话 ID。 */
  sessionId: Id;
  /** 手写目标。 */
  target: HandwritingTarget;
  /** 笔迹文档。 */
  document: StrokeDocument;
  /** 是否有未保存改动。 */
  dirty: boolean;
  /** 更新时间。 */
  updatedAt: EpochMs;
}

/** 识别错误码。 */
export type RecognitionErrorCode =
  | 'timeout'
  | 'empty-text'
  | 'service-unavailable'
  | 'unsupported-mode'
  | 'internal-error';

/** 识别成功结果。 */
export interface RecognitionSuccess {
  /** 判别字段：成功。 */
  ok: true;
  /** 请求 ID。 */
  requestId: Id;
  /** 识别文本（确认答案后才返回，不展示候选/置信度）。 */
  text: string;
  /** 模型版本。 */
  modelVersion: string;
  /** 耗时（毫秒）。 */
  durationMs: number;
}

/** 识别失败结果（保留笔迹，允许重试/重写）。 */
export interface RecognitionFailure {
  /** 判别字段：失败。 */
  ok: false;
  /** 请求 ID。 */
  requestId: Id;
  /** 错误码。 */
  errorCode: RecognitionErrorCode;
  /** 是否可重试。 */
  retryable: boolean;
  /** 耗时（毫秒）。 */
  durationMs: number;
}

/** 识别结果（成功或失败）。 */
export type RecognitionResult = RecognitionSuccess | RecognitionFailure;

/** 识别句柄（可取消的进行中识别）。 */
export interface RecognitionHandle {
  /** 请求 ID。 */
  requestId: Id;
  /** 识别结果 Promise。 */
  result: Promise<RecognitionResult>;
  /** 取消本次识别。 */
  cancel(): void;
}

/** 手写识别器契约（仅在用户点击「确认答案」后调用，CLAUDE.md §8）。 */
export interface HandwritingRecognizer {
  /**
   * 提交笔迹识别。
   * @param input 笔迹文档
   * @param mode 识别模式
   * @returns 可取消的识别句柄
   */
  recognize(input: StrokeDocument, mode: HandwritingMode): RecognitionHandle;
}

/** 手写服务契约（会话/草稿/识别编排；笔迹采集/橡皮擦/撤销归本服务，04 §12 规则9）。 */
export interface HandwritingService {
  /**
   * 开始笔迹会话。
   * @param target 手写目标
   * @returns 笔迹会话
   */
  begin(target: HandwritingTarget): StrokeSession;
  /**
   * 持久化草稿快照。
   * @param session 笔迹会话
   */
  persistDraft(session: StrokeSession): Promise<void>;
  /**
   * 提交识别。
   * @param session 笔迹会话
   * @returns 识别句柄
   */
  recognize(session: StrokeSession): RecognitionHandle;
}
