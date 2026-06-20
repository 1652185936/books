/**
 * 导入任务仓储（P1-3，LLD §2.3 状态机持久化 + §3.22 import_jobs / §3.23 package_files）。
 *
 * 「导入状态机持久化于 `import_jobs`」（§2.6 后台执行/重启恢复的载体）。本仓储是状态机的持久化边界：
 * - 所有状态推进经 `transition(...)`，在事务内**先读当前状态 → `ImportStateMachine.assertTransition` 守卫 →
 *   再写**，杜绝把非法状态写入库（不变量守卫）。
 * - `package_files` 逐文件记录期望/实际哈希与校验态（pending/valid/warning/invalid），供 SHA-256 比对与报告。
 * - 页面/ViewModel 不碰 SQL，一律经本仓储（CLAUDE.md §5）；写入经 `runInTransaction`（LLD §8）。
 *
 * 未编译验证（缺 HarmonyOS SDK）：relationalStore `executeSql`/`ResultSet`/事务 API 以 API 12 为准。
 */
import { relationalStore } from '@kit.ArkData';
import { Database } from '../database/Database';
import { BaseRepository, RowMapper } from './BaseRepository';
import { AppErrors, DB_WRITE_FAILED } from '../utils/AppErrors';
import { ImportState, ImportStateMachine } from '../services/import/ImportStateMachine';

/** 单个文件校验态（§3.23 `validation_state` CHECK 取值）。 */
export type PackageFileValidationState = 'pending' | 'valid' | 'warning' | 'invalid';

/** `import_jobs` 行记录（§3.22，字段名对齐列名的驼峰映射）。 */
export interface ImportJobRecord {
  /** 任务 ID（PK）。 */
  id: string;
  /** 脱敏文件名。 */
  sourceName: string;
  /** 文件大小（字节，≥0）。 */
  sourceSize: number;
  /** URI 哈希（不保存原 URI）。 */
  sourceUriHash: string;
  /** 解析后包 ID（解析前为 undefined）。 */
  packageId?: string;
  /** 导入状态机值。 */
  state: ImportState;
  /** 当前阶段（诊断/进度展示用，常为状态或其 04 事件阶段）。 */
  currentStage: string;
  /** 进度 0..1。 */
  progress: number;
  /** 警告数（IMP-015 累计）。 */
  warningCount: number;
  /** 错误码（失败时存在）。 */
  errorCode?: string;
  /** 脱敏错误摘要（≤1000）。 */
  errorDetail?: string;
  /** 开始时间（epoch ms）。 */
  startedAt: number;
  /** 完成时间（epoch ms，未完成为 undefined）。 */
  completedAt?: number;
}

/** `package_files` 行记录（§3.23）。 */
export interface PackageFileRecord {
  /** 包内相对路径。 */
  relativePath: string;
  /** 期望哈希（来自 checksums.json）。 */
  expectedSha256?: string;
  /** 实际哈希（暂存计算所得）。 */
  actualSha256?: string;
  /** 大小（字节，≥0）。 */
  sizeBytes: number;
  /** 校验态（默认 pending）。 */
  validationState: PackageFileValidationState;
  /** 错误码（该文件校验失败时）。 */
  errorCode?: string;
}

/** 状态推进时一并更新的字段（除 state 外的可选补丁）。 */
export interface TransitionPatch {
  /** 当前阶段标识（默认取目标状态值）。 */
  stage?: string;
  /** 进度 0..1（默认沿用原值）。 */
  progress?: number;
  /** 错误码（进入 failed 时写入）。 */
  errorCode?: string;
  /** 脱敏错误摘要。 */
  errorDetail?: string;
  /** 警告数（覆盖写入）。 */
  warningCount?: number;
  /** 解析后包 ID。 */
  packageId?: string;
  /** 完成时间（进入 completed/cancelled/failed 终态时写入）。 */
  completedAt?: number;
}

/**
 * 导入任务仓储。
 */
export class ImportJobRepository extends BaseRepository {
  /**
   * @param database 已就绪的数据库封装。
   */
  constructor(database: Database) {
    super(database);
  }

  /**
   * 行 → ImportJobRecord 映射器（仅读当前行，不移动游标）。
   * @param cursor 结果集游标。
   * @returns 任务记录。
   */
  private static mapJob: RowMapper<ImportJobRecord> = (cursor: relationalStore.ResultSet): ImportJobRecord => {
    // 逐列读取（可空列经 isColumnNull 判空转 undefined）
    const record: ImportJobRecord = {
      id: cursor.getString(cursor.getColumnIndex('id')),
      sourceName: cursor.getString(cursor.getColumnIndex('source_name')),
      sourceSize: cursor.getLong(cursor.getColumnIndex('source_size')),
      sourceUriHash: cursor.getString(cursor.getColumnIndex('source_uri_hash')),
      state: cursor.getString(cursor.getColumnIndex('state')) as ImportState,
      currentStage: cursor.getString(cursor.getColumnIndex('current_stage')),
      progress: cursor.getDouble(cursor.getColumnIndex('progress')),
      warningCount: cursor.getLong(cursor.getColumnIndex('warning_count')),
      startedAt: cursor.getLong(cursor.getColumnIndex('started_at'))
    };
    // 可空：package_id
    const packageIdIdx: number = cursor.getColumnIndex('package_id');
    if (!cursor.isColumnNull(packageIdIdx)) {
      record.packageId = cursor.getString(packageIdIdx);
    }
    // 可空：error_code
    const errorCodeIdx: number = cursor.getColumnIndex('error_code');
    if (!cursor.isColumnNull(errorCodeIdx)) {
      record.errorCode = cursor.getString(errorCodeIdx);
    }
    // 可空：error_detail
    const errorDetailIdx: number = cursor.getColumnIndex('error_detail');
    if (!cursor.isColumnNull(errorDetailIdx)) {
      record.errorDetail = cursor.getString(errorDetailIdx);
    }
    // 可空：completed_at
    const completedAtIdx: number = cursor.getColumnIndex('completed_at');
    if (!cursor.isColumnNull(completedAtIdx)) {
      record.completedAt = cursor.getLong(completedAtIdx);
    }
    return record;
  };

  /**
   * 插入新导入任务（一般以 `state='selected'`、`progress=0` 起始）。
   * @param record 任务记录。
   * @returns 完成插入的 Promise。
   * @throws AppError 写入失败时抛出。
   */
  async insertJob(record: ImportJobRecord): Promise<void> {
    await this.runInTransaction(async (store: relationalStore.RdbStore): Promise<void> => {
      // 绑定参数（与列顺序一一对应；可空字段缺省传 null）
      const args: relationalStore.ValueType[] = [
        record.id, record.sourceName, record.sourceSize, record.sourceUriHash,
        record.packageId !== undefined ? record.packageId : null,
        record.state, record.currentStage, record.progress, record.warningCount,
        record.errorCode !== undefined ? record.errorCode : null,
        record.errorDetail !== undefined ? AppErrors.sanitizeDetail(record.errorDetail) : null,
        record.startedAt,
        record.completedAt !== undefined ? record.completedAt : null
      ];
      await store.executeSql(
        'INSERT INTO import_jobs (id, source_name, source_size, source_uri_hash, package_id, state, '
        + 'current_stage, progress, warning_count, error_code, error_detail, started_at, completed_at) '
        + 'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', args);
    });
  }

  /**
   * 取任务记录。
   * @param jobId 任务 ID。
   * @returns 任务记录或 undefined。
   */
  getJob(jobId: string): Promise<ImportJobRecord | undefined> {
    return this.querySingle('SELECT * FROM import_jobs WHERE id = ?', ImportJobRepository.mapJob, [jobId]);
  }

  /**
   * 按状态集合列出任务（重启恢复扫描「非终态」任务时使用，§2.6；P1-5 消费）。
   * @param states 状态集合（非空）。
   * @returns 任务记录数组。
   */
  listByStates(states: ImportState[]): Promise<ImportJobRecord[]> {
    if (states.length === 0) {
      return Promise.resolve([]);
    }
    // IN 占位符与绑定参数
    const placeholders: string = states.map((): string => '?').join(', ');
    const args: relationalStore.ValueType[] = states.slice();
    return this.queryList(
      `SELECT * FROM import_jobs WHERE state IN (${placeholders}) ORDER BY started_at ASC`,
      ImportJobRepository.mapJob, args);
  }

  /**
   * 统计同一 `package_id` 下处于非终态（进行中）的其它导入/升级任务数（§2.7 / §8 单飞守卫）。
   * 终态 `completed`/`cancelled`/`failed` 不计入；`excludeJobId` 自身排除。
   * @param packageId 包 ID。
   * @param excludeJobId 排除的任务 ID（当前任务自身）。
   * @returns 非终态在飞任务数。
   * @throws AppError 查询失败时抛出。
   */
  async countActiveJobsForPackage(packageId: string, excludeJobId: string): Promise<number> {
    // 行 → 计数映射
    const mapper: RowMapper<number> =
      (cursor: relationalStore.ResultSet): number => cursor.getLong(cursor.getColumnIndex('n'));
    // 非终态在飞任务计数（排除自身）
    const count: number | undefined = await this.querySingle(
      "SELECT COUNT(*) AS n FROM import_jobs WHERE package_id = ? AND id != ? "
      + "AND state NOT IN ('completed', 'cancelled', 'failed')",
      mapper, [packageId, excludeJobId]);
    return count !== undefined ? count : 0;
  }

  /**
   * 守卫式状态推进：事务内读当前状态 → 校验合法转移 → 更新 state 及补丁字段。
   * @param jobId 任务 ID。
   * @param to 目标状态。
   * @param patch 一并更新的字段（stage/progress/error/warning/packageId/completedAt）。
   * @returns 完成更新的 Promise。
   * @throws AppError 任务不存在、转移非法或写入失败时抛出。
   */
  async transition(jobId: string, to: ImportState, patch?: TransitionPatch): Promise<void> {
    // 归一化补丁
    const p: TransitionPatch = patch !== undefined ? patch : {};
    await this.runInTransaction(async (store: relationalStore.RdbStore): Promise<void> => {
      // 读当前状态（事务内，避免并发竞态）
      const current: ImportJobRecord | undefined =
        await this.querySingle('SELECT * FROM import_jobs WHERE id = ?', ImportJobRepository.mapJob, [jobId]);
      if (current === undefined) {
        throw AppErrors.create(DB_WRITE_FAILED, { detail: `import-job-not-found:${jobId}` });
      }
      // 守卫：非法转移即抛错（不写库）
      ImportStateMachine.assertTransition(current.state, to);

      // 计算落库值（补丁缺省时沿用原值 / 安全默认）
      const stage: string = p.stage !== undefined ? p.stage : to;
      const progress: number = p.progress !== undefined ? p.progress : current.progress;
      const warningCount: number = p.warningCount !== undefined ? p.warningCount : current.warningCount;
      const packageId: relationalStore.ValueType =
        p.packageId !== undefined ? p.packageId : (current.packageId !== undefined ? current.packageId : null);
      const errorCode: relationalStore.ValueType = p.errorCode !== undefined ? p.errorCode : null;
      const errorDetail: relationalStore.ValueType =
        p.errorDetail !== undefined ? AppErrors.sanitizeDetail(p.errorDetail) : null;
      const completedAt: relationalStore.ValueType = p.completedAt !== undefined ? p.completedAt : null;

      await store.executeSql(
        'UPDATE import_jobs SET state = ?, current_stage = ?, progress = ?, warning_count = ?, '
        + 'package_id = ?, error_code = ?, error_detail = ?, completed_at = ? WHERE id = ?',
        [to, stage, progress, warningCount, packageId, errorCode, errorDetail, completedAt, jobId]);
    });
  }

  /**
   * 写入/覆盖单个 `package_files` 行（同 `(import_job_id, relative_path)` 即覆盖）。
   * @param jobId 任务 ID。
   * @param file 文件记录。
   * @returns 完成写入的 Promise。
   */
  async upsertFile(jobId: string, file: PackageFileRecord): Promise<void> {
    await this.runInTransaction(async (store: relationalStore.RdbStore): Promise<void> => {
      // 绑定参数（可空哈希/错误码缺省传 null）
      const args: relationalStore.ValueType[] = [
        jobId, file.relativePath,
        file.expectedSha256 !== undefined ? file.expectedSha256 : null,
        file.actualSha256 !== undefined ? file.actualSha256 : null,
        file.sizeBytes, file.validationState,
        file.errorCode !== undefined ? file.errorCode : null
      ];
      await store.executeSql(
        'INSERT OR REPLACE INTO package_files (import_job_id, relative_path, expected_sha256, '
        + 'actual_sha256, size_bytes, validation_state, error_code) VALUES (?, ?, ?, ?, ?, ?, ?)', args);
    });
  }
}
