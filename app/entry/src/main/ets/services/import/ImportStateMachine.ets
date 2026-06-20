/**
 * 导入状态机（P1-3，LLD §2.3 状态图 + §2.5 错误码 + §2.6 重试分类）。
 *
 * 单一真值：本模块按 LLD §2.3 mermaid 状态图逐边固化「合法状态转移表」，并据 R-056/R-015：
 * - 把「阶段失败」映射到既有 IMP-* 错误码（copying→IMP-017、extracting→IMP-018、indexing→IMP-019、
 *   committing→IMP-016；磁盘满任意阶段→IMP-013）；校验类阶段（zip/manifest/hash/schema/business）的
 *   具体码来自各自校验器（P1-1/P1-2 + ChecksumVerifier），不在此臆造。
 * - 区分「可重试」（环境/IO 类：IMP-013/016/017/019）与「终态拒绝」（内容类：其余），供构造 AppError.retryable。
 * - 提供「持久化状态（snake_case，落 `import_jobs.state`）→ 04 契约事件阶段（kebab-case）」映射，
 *   作为 ValidationEvent/ImportPhaseEvent 的 `stage`（《04》§2）。
 *
 * 纯逻辑、零 `@ohos.*` 依赖、可单测；实际的暂存读写/哈希计算分别由 ImportStaging/ChecksumVerifier 承担。
 *
 * 错误码与文案：本模块只产出 IMP-* 码；用户可读文案经 `AppErrors.create` 走 §3.14A error_code→资源键映射。
 */
import { AppError } from '../../domain/entities/common';
import { AppErrors } from '../../utils/AppErrors';
import { ValidationStage } from '../../domain/entities/import';

/**
 * 导入状态机状态值（与 LLD §2.3 mermaid 节点逐一对应，snake_case 即 `import_jobs.state` 落库值）。
 */
export type ImportState =
  | 'selected'
  | 'copying'
  | 'validating_zip'
  | 'validating_manifest'
  | 'extracting_to_staging'
  | 'validating_hash'
  | 'validating_schema'
  | 'validating_business'
  | 'awaiting_confirmation'
  | 'indexing'
  | 'promoting_to_final'
  | 'committing'
  | 'completed'
  | 'cancelled'
  | 'failed';

/**
 * 合法状态转移表（逐边对齐 LLD §2.3 状态图）。键=起始状态，值=允许到达的目标状态集合。
 * 注意：`selected`/`awaiting_confirmation` 在图中**无** `→failed` 边；`failed→copying` 为重试回边（R-015）。
 */
export const IMPORT_TRANSITIONS: Record<ImportState, ImportState[]> = {
  // selected：开始复制或在写库前取消
  selected: ['copying', 'cancelled'],
  // copying：进入 ZIP 校验；可取消；通用 IO/磁盘满失败
  copying: ['validating_zip', 'cancelled', 'failed'],
  // validating_zip：进入 manifest 校验；可取消；失败
  validating_zip: ['validating_manifest', 'cancelled', 'failed'],
  // validating_manifest：进入解压暂存；可取消；失败
  validating_manifest: ['extracting_to_staging', 'cancelled', 'failed'],
  // extracting_to_staging：进入哈希校验；可取消；解压损坏失败
  extracting_to_staging: ['validating_hash', 'cancelled', 'failed'],
  // validating_hash：进入 Schema 校验；可取消；哈希不符失败
  validating_hash: ['validating_schema', 'cancelled', 'failed'],
  // validating_schema：进入业务校验；可取消；Schema 失败
  validating_schema: ['validating_business', 'cancelled', 'failed'],
  // validating_business：进入待确认；可取消；业务校验失败
  validating_business: ['awaiting_confirmation', 'cancelled', 'failed'],
  // awaiting_confirmation：用户确认进入建索引；超时/主动取消（§2.6，图中无 →failed 边）
  awaiting_confirmation: ['indexing', 'cancelled'],
  // indexing：建索引成功进入目录提升；失败（不可再取消）
  indexing: ['promoting_to_final', 'failed'],
  // promoting_to_final：原子提升成功进入提交；失败
  promoting_to_final: ['committing', 'failed'],
  // committing：提交成功完成；提交失败
  committing: ['completed', 'failed'],
  // completed：终态
  completed: [],
  // cancelled：终态
  cancelled: [],
  // failed：可重试回到 copying（复用同一 jobId，R-015），否则终态停留
  failed: ['copying']
};

/** 终态集合（不再自动推进；`failed` 需用户显式重试/放弃，按终态对待）。 */
const TERMINAL_STATES: ImportState[] = ['completed', 'cancelled', 'failed'];

/**
 * 阶段失败 → 既有 IMP-* 错误码（R-056，§2.5）。
 * 仅覆盖「码唯一由阶段决定」的 IO/结构性阶段；校验类阶段的码来自各校验器，返回 undefined 由调用方提供。
 */
const STAGE_FAILURE_CODE: Record<string, string> = {
  // 复制到暂存区失败（非磁盘满的通用 IO）
  copying: 'IMP-017',
  // 解压失败（条目损坏/解码失败，区别于路径穿越 IMP-002 / 压缩炸弹 IMP-004）
  extracting_to_staging: 'IMP-018',
  // 建索引失败（区别于提交失败 IMP-016）
  indexing: 'IMP-019',
  // 数据库提交失败
  committing: 'IMP-016'
};

/** 磁盘空间不足错误码（任意阶段统一记此码，R-056）。 */
export const DISK_FULL_CODE: string = 'IMP-013';

/** 可重试错误码集合（环境/IO 类，R-015 / §2.6）：存储不足、提交失败、复制失败、建索引失败。 */
const RETRYABLE_CODES: string[] = ['IMP-013', 'IMP-016', 'IMP-017', 'IMP-019'];

/**
 * 持久化状态（snake_case）→ 04 契约事件阶段（kebab-case，《04》§2 ValidationStage/ImportPhaseEvent.stage）。
 * 不在映射内的状态（selected/copying/cancelled/failed）不作为对外进度事件阶段，返回 undefined。
 */
const STATE_TO_DTO_STAGE: Record<string, string> = {
  validating_zip: 'validating-zip',
  validating_manifest: 'validating-manifest',
  extracting_to_staging: 'extracting-to-staging',
  validating_hash: 'validating-hash',
  validating_schema: 'validating-schema',
  validating_business: 'validating-business',
  awaiting_confirmation: 'awaiting-confirmation',
  indexing: 'indexing',
  promoting_to_final: 'promoting-to-final',
  committing: 'committing',
  completed: 'completed'
};

/** 构造阶段失败错误的可选项。 */
export interface FailureOptions {
  /** 是否磁盘空间不足（任意阶段统一记 IMP-013，覆盖阶段默认码）。 */
  diskFull?: boolean;
  /** 脱敏诊断详情（不含完整正文/笔迹/敏感路径，写入前再经 AppErrors 截断）。 */
  detail?: string;
}

/**
 * 导入状态机（静态方法集合，风格与 ZipSafetyValidator/PackageSchemaValidator 一致）。
 */
export class ImportStateMachine {
  /**
   * 判断从 `from` 到 `to` 是否为合法状态转移。
   * @param from 起始状态。
   * @param to 目标状态。
   * @returns 合法返回 true。
   */
  static canTransition(from: ImportState, to: ImportState): boolean {
    // 起始状态允许到达的目标集合（Record 索引运行期可能 undefined，显式判空）
    const targets: ImportState[] | undefined = IMPORT_TRANSITIONS[from];
    return targets !== undefined && targets.indexOf(to) >= 0;
  }

  /**
   * 校验状态转移；非法时抛出领域错误（持久化前的不变量守卫，避免写入非法状态）。
   * @param from 起始状态。
   * @param to 目标状态。
   * @throws AppError 非法转移时抛出 `DB_WRITE_FAILED`（脱敏 detail 含 from→to）。
   */
  static assertTransition(from: ImportState, to: ImportState): void {
    if (!ImportStateMachine.canTransition(from, to)) {
      throw AppErrors.create('DB_WRITE_FAILED', { detail: `illegal-import-transition:${from}->${to}` });
    }
  }

  /**
   * 是否终态（completed/cancelled/failed）。重启恢复扫描「非终态」任务即取反。
   * @param state 状态。
   * @returns 终态返回 true。
   */
  static isTerminal(state: ImportState): boolean {
    return TERMINAL_STATES.indexOf(state) >= 0;
  }

  /**
   * 当前状态是否可转入 `cancelled`（§2.6：写库前各阶段可取消，`indexing` 及之后不可）。
   * @param state 状态。
   * @returns 可取消返回 true。
   */
  static isCancellable(state: ImportState): boolean {
    return ImportStateMachine.canTransition(state, 'cancelled');
  }

  /**
   * 取阶段失败的默认 IMP-* 错误码（仅 copying/extracting/indexing/committing 有唯一码）。
   * 校验类阶段返回 undefined（其码由对应校验器给出）。
   * @param state 失败发生的阶段状态。
   * @returns IMP-* 错误码或 undefined。
   */
  static defaultFailureCodeForStage(state: ImportState): string | undefined {
    // 阶段→码映射命中值（未命中为 undefined）
    const code: string | undefined = STAGE_FAILURE_CODE[state];
    return code;
  }

  /**
   * 错误码是否可重试（环境/IO 类，R-015）。
   * @param code IMP-* 错误码。
   * @returns 可重试返回 true。
   */
  static isRetryable(code: string): boolean {
    return RETRYABLE_CODES.indexOf(code) >= 0;
  }

  /**
   * 持久化状态 → 04 契约对外事件阶段（kebab-case）；无对外阶段（selected/copying/cancelled/failed）返回 undefined。
   * @param state 持久化状态。
   * @returns 事件阶段字符串或 undefined。
   */
  static toDtoStage(state: ImportState): string | undefined {
    // 状态→事件阶段映射命中值
    const stage: string | undefined = STATE_TO_DTO_STAGE[state];
    return stage;
  }

  /**
   * 是否为 04 契约「校验阶段」事件（ValidationEvent.stage 取值范围）。
   * @param stage 事件阶段字符串。
   * @returns 属于校验阶段返回 true。
   */
  static isValidationStage(stage: string): stage is ValidationStage {
    return stage === 'validating-zip'
      || stage === 'validating-manifest'
      || stage === 'extracting-to-staging'
      || stage === 'validating-hash'
      || stage === 'validating-schema'
      || stage === 'validating-business';
  }

  /**
   * 为某一阶段失败构造领域错误：选定 IMP-* 码并按 R-015 设置 retryable，文案走 §3.14A 映射。
   * - `diskFull=true` → 任意阶段统一 IMP-013（可重试）。
   * - 否则取阶段默认码（IO/结构阶段）；校验类阶段无默认码时抛错（调用方应改用 `buildFailure(code,…)`）。
   * @param state 失败发生的阶段状态。
   * @param options 失败选项（磁盘满 / 脱敏 detail）。
   * @returns 阻断错误 AppError。
   */
  static buildStageFailure(state: ImportState, options?: FailureOptions): AppError {
    // 归一化选项
    const opts: FailureOptions = options !== undefined ? options : {};
    // 选定错误码：磁盘满优先，其次阶段默认码
    const code: string | undefined = opts.diskFull === true
      ? DISK_FULL_CODE
      : ImportStateMachine.defaultFailureCodeForStage(state);
    if (code === undefined) {
      // 校验类阶段无唯一默认码，必须由校验器给出具体码
      throw AppErrors.create('DB_WRITE_FAILED', { detail: `no-default-failure-code-for-stage:${state}` });
    }
    return ImportStateMachine.buildFailure(code, opts.detail);
  }

  /**
   * 以指定 IMP-* 码构造阻断错误，retryable 按 R-015 自动推导，文案走 §3.14A 映射。
   * @param code IMP-* 错误码（来自阶段默认或各校验器）。
   * @param detail 脱敏诊断详情（可选）。
   * @returns 阻断错误 AppError。
   */
  static buildFailure(code: string, detail?: string): AppError {
    return AppErrors.create(code, { retryable: ImportStateMachine.isRetryable(code), detail: detail });
  }
}
