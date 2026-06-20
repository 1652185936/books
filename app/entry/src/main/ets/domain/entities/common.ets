/**
 * 通用类型契约（《04-接口与DTO契约》§1，MX-API-001 v1.2.0）。
 * 跨模块共享的基础类型，其余各域 DTO 文件均从此处导入。唯一真值为 04 契约，
 * 不得在他处自增必填字段或改变语义（CLAUDE.md §3 优先级链）。
 *
 * 未编译验证（缺 HarmonyOS SDK）：本模块全 11 个 DTO 文件已用独立 TypeScript 编译器（tsc --strict --noEmit）
 * 交叉核验通过，跨文件 import/导出引用、联合类型、interface extends 与泛型均自洽。唯一例外是下方 JsonObject：
 * 其「递归 Record 取值」形式被标准 tsc 判为 TS2456（循环引用），此为 ArkTS 与 tsc 的已知分歧——ArkTS 强制用
 * Record 表达字符串键动态对象并禁止索引签名，而 tsc 恰好接受 ArkTS 所禁止的递归索引签名对象、拒绝递归 Record 别名。
 * 此处保持《04 契约》§1 字面定义不变，最终可编译性以 HarmonyOS SDK 实测为准；若 ArkTS 亦拒绝，再按优先级链在
 * 《已知冲突与裁决记录》登记裁决，本轮不擅自改写规格结构。
 */

/** 内部主键标识（TEXT，UUIDv7 或等价有序唯一 ID，LLD §1.3）。 */
export type Id = string;

/** UTC Unix 毫秒时间戳（INTEGER，LLD §1.3）。 */
export type EpochMs = number;

/**
 * 可序列化 JSON 对象载体（payload / context / scrollAnchor 等字段）。
 * 值仅允许 JSON 基本类型与嵌套对象/数组；写库前必须解析-校验-重新序列化（LLD §1.3）。
 */
export type JsonObject = Record<string, string | number | boolean | null | JsonObject | JsonObject[]>;

/** 分页请求。 */
export interface PageRequest {
  /** 游标，省略表示从头开始。 */
  cursor?: string;
  /** 单页条数，取值 1..100。 */
  limit: number;
}

/** 分页结果。 */
export interface PageResult<T> {
  /** 当前页数据。 */
  items: T[];
  /** 下一页游标，省略表示无更多数据。 */
  nextCursor?: string;
  /** 总条数（可选，部分查询不返回）。 */
  total?: number;
}

/**
 * 领域错误。所有 Promise 失败必须抛出或返回可转换为 AppError 的领域错误，不得抛裸字符串（04 §1）。
 */
export interface AppError {
  /** 错误码（与 LLD §3.14A error_code 对应）。 */
  code: string;
  /** 用户可见文案的资源键（禁止硬编码，CLAUDE.md §5）。 */
  messageKey: string;
  /** 是否可重试。 */
  retryable: boolean;
  /** 已脱敏诊断详情，最多 1000 字符；禁止含完整正文/笔迹/敏感路径。 */
  detail?: string;
}
