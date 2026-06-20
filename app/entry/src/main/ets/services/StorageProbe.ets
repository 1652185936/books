/**
 * 存储与来源探测端口（F02，LLD §6.2「空间不足」状态 + §2.2 暂存目录）。
 *
 * P-F02 导入选择页在「选择文件 → 预检查 → 开始校验」之间需要两类设备 IO：
 * 1. 探测所选来源文件的脱敏文件名与字节大小（落 `import_jobs.source_name`/`source_size`，§3.22）；
 * 2. 探测暂存盘可用空间，与「来源大小 + 解压余量」比较以提前判定「空间不足」（FR-F02 空间检查），
 *    避免复制中途因 IMP-013 失败才暴露。
 *
 * 这两类操作都依赖 HarmonyOS SDK（`@ohos.file.fs` / `statfs` / `DocumentViewPicker` 返回的 fileUri），
 * 故在此抽象为纯接口端口 `SourceProbePort` / `FreeSpaceProbePort`，逻辑层 `StorageProbe` 只做无 IO 的
 * 空间充足性判定（可单测）；生产侧适配器（依赖 SDK）在页面装配处注入，本模块零 `@ohos.*` 依赖。
 *
 * 未编译验证（缺 HarmonyOS SDK）：生产适配器的 `@ohos.file.fs.stat` / `@ohos.file.statvfs` 形态以 API 12 为准。
 */
import { AppError } from '../domain/entities/common';

/** 所选来源文件的脱敏元信息（不含原始 URI / 绝对路径，CLAUDE.md §5）。 */
export interface SourceFileMeta {
  /** 脱敏显示文件名（仅末段文件名，不含目录路径）。 */
  displayName: string;
  /** 文件字节大小（≥0）。 */
  sizeBytes: number;
}

/**
 * 来源文件探测端口：由所选 URI 取脱敏文件名与大小。
 * 生产实现依赖 `DocumentViewPicker` 返回的 fileUri + `@ohos.file.fs.stat`；单测以内存假实现注入。
 */
export interface SourceProbePort {
  /**
   * 探测来源文件的脱敏元信息。
   * @param sourceUri 来源文件 URI（仅在本端口内部使用，不向上层/日志泄漏）。
   * @returns 脱敏文件名与字节大小。
   * @throws AppError 文件不存在或无法读取时抛出。
   */
  probeSource(sourceUri: string): Promise<SourceFileMeta>;
}

/**
 * 可用空间探测端口：取暂存盘当前可用字节数。
 * 生产实现依赖 `@ohos.file.statvfs`（对 `context.tempDir`）；单测以内存假实现注入。
 */
export interface FreeSpaceProbePort {
  /**
   * 取暂存盘可用字节数。
   * @returns 可用字节数（≥0）。
   * @throws AppError 探测失败时抛出。
   */
  freeBytes(): Promise<number>;
}

/** 空间充足性判定结论（结构化，供页面切到「空间不足」状态并展示所需/可用对比）。 */
export interface SpaceCheckResult {
  /** 是否空间充足（可用 ≥ 预估所需）。 */
  sufficient: boolean;
  /** 预估所需字节数（来源大小 × 余量系数）。 */
  requiredBytes: number;
  /** 当前可用字节数。 */
  availableBytes: number;
}

/**
 * 默认空间余量系数：解压 + 暂存副本需要超过压缩包本身的空间，按来源大小的若干倍预留。
 * 取较保守的 3 倍（原压缩包副本 1 份 + 解压展开估算 ~2 份），避免复制/解压中途 IMP-013。
 */
const DEFAULT_HEADROOM_FACTOR: number = 3;

/**
 * 存储空间充足性判定（纯逻辑，无 IO）。
 * 实际可用空间/来源大小由端口探测注入；本类只做「可用是否覆盖预估所需」的确定性比较，便于单测。
 */
export class StorageProbe {
  /** 空间余量系数（来源大小的倍数）。 */
  private readonly headroomFactor: number;

  /**
   * @param headroomFactor 空间余量系数，缺省 3（不传或非正数回退默认值）。
   */
  constructor(headroomFactor?: number) {
    // 余量系数：非正数（含 0/负数/NaN）一律回退默认，杜绝把所需算成 0
    this.headroomFactor = headroomFactor !== undefined && headroomFactor > 0
      ? headroomFactor
      : DEFAULT_HEADROOM_FACTOR;
  }

  /**
   * 预估导入某来源所需的暂存字节数（来源大小 × 余量系数，向上取整）。
   * @param sourceSizeBytes 来源压缩包字节大小（≥0）。
   * @returns 预估所需字节数。
   */
  estimateRequiredBytes(sourceSizeBytes: number): number {
    // 负数来源大小按 0 处理（防御性），再乘余量系数并向上取整
    const safeSize: number = sourceSizeBytes > 0 ? sourceSizeBytes : 0;
    return Math.ceil(safeSize * this.headroomFactor);
  }

  /**
   * 判定可用空间是否足以容纳某来源的导入暂存。
   * @param sourceSizeBytes 来源压缩包字节大小（≥0）。
   * @param availableBytes 暂存盘当前可用字节数（≥0）。
   * @returns 空间充足性结论（含所需/可用明细，供页面对比展示）。
   */
  checkSpace(sourceSizeBytes: number, availableBytes: number): SpaceCheckResult {
    // 预估所需字节数（含余量）
    const requiredBytes: number = this.estimateRequiredBytes(sourceSizeBytes);
    // 可用 ≥ 所需即充足
    const sufficient: boolean = availableBytes >= requiredBytes;
    return { sufficient, requiredBytes, availableBytes };
  }
}
