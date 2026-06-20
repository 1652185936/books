/**
 * 通用 JSON Schema 校验引擎（P1-2，JSON Schema draft 2020-12 子集）。
 *
 * 用途：在导入校验 §2.4 step8 用**应用内置** Schema 校验暂存目录内的结构化 JSON
 * （manifest/book/chapter/report/checksums）。本文件只做「Schema + 实例 → 违规列表」的纯计算，
 * 不读文件、不依赖 `@ohos.*`、不持任何状态；文件 IO 与错误码包装分别由 P1-3 / `PackageSchemaValidator` 负责。
 *
 * 受支持关键字（恰好覆盖 `packages/studybook-schema/` 五个内置 Schema 实际用到的构造，可追溯）：
 * - 类型/取值：`type`(含 integer)、`const`、`enum`、`pattern`；
 * - 对象：`properties`、`required`、`additionalProperties`(布尔或子 Schema)、`minProperties`；
 * - 数组：`items`(单一子 Schema)、`minItems`；
 * - 字符串：`minLength`；数值：`minimum`、`maximum`；
 * - 组合：`allOf`、`if`/`then`/`else`、布尔子 Schema(`true`/`false`)。
 * 注解类关键字（`$schema`/`$id`/`title`/`description`/`comment`/`$comment`/`examples`/`default`/`$vocabulary`）一律忽略。
 *
 * `format`（如 manifest.createdAt 的 `date-time`）按 JSON Schema 2020-12 默认语义作**注解处理、不断言**
 * （这些 Schema 未声明 format-assertion 词表），避免误报 IMP-008；时间戳的业务有效性归 §2.4 step9 业务校验。
 *
 * 安全/脱敏：违规项只记录「JSON 路径 + 关键字 + 结构化原因」，**绝不包含实例值**（CLAUDE.md §5：不输出正文/笔迹）。
 *
 * 未编译验证（缺 HarmonyOS SDK）：`JsonValue` 采用「递归 Record 联合」表达任意 JSON 值树——这是 ArkTS
 * 表达动态对象的既定写法（ArkTS 接受递归 Record，标准 tsc 判 TS2456，详见 `common.ets` 头注释同款分歧）。
 * 本文件逻辑已用等价 Node 端口 + 真实夹具回归验证；最终可编译性以 SDK 实测为准。
 */

/**
 * 任意 JSON 值树。需要顶层数组/原始值与嵌套 `null`，故不复用只能表达字符串键对象的 `JsonObject`。
 * 递归 Record 是 ArkTS 动态对象的既定表达形式。
 */
export type JsonValue =
  | null
  | boolean
  | number
  | string
  | JsonValue[]
  | Record<string, JsonValue>;

/** 单条 Schema 违规（仅结构化诊断，不含实例值）。 */
export interface SchemaViolation {
  /** 违规实例位置（类 JSON Pointer，如 `/book/chapterCount`、`/toc/0/file`）。 */
  path: string;
  /** 触发违规的关键字（如 `type`/`required`/`pattern`）。 */
  keyword: string;
  /** 简短结构化原因（如 `expected=integer`、`missing=chapterCount`），不含实例值。 */
  hint: string;
}

/** 违规收集上限（防异常巨型实例产生超长列表；正常包远不及此）。 */
const MAX_VIOLATIONS: number = 200;

/** 引擎忽略的注解类关键字集合（出现即跳过，不参与断言）。 */
const ANNOTATION_KEYWORDS: string[] = [
  '$schema', '$id', '$ref', '$defs', '$vocabulary', '$comment',
  'title', 'description', 'comment', 'examples', 'default'
];

/**
 * 通用 JSON Schema 校验引擎（静态方法集合，无状态）。
 */
export class JsonSchemaValidator {
  /**
   * 校验实例是否满足 Schema，返回全部违规（空数组表示通过）。
   * @param schema JSON Schema 节点（对象或布尔 Schema）。
   * @param instance 待校验的 JSON 实例值。
   * @returns 违规列表（空=通过）。
   */
  static validate(schema: JsonValue, instance: JsonValue): SchemaViolation[] {
    // 违规累积容器（按校验顺序追加）
    const errors: SchemaViolation[] = [];
    JsonSchemaValidator.validateNode(schema, instance, '', errors);
    return errors;
  }

  /**
   * 校验单个 Schema 节点（递归核心）。命中违规时追加到 `errors`（受 MAX_VIOLATIONS 上限保护）。
   * @param schema 当前 Schema 节点。
   * @param instance 当前实例值。
   * @param path 当前实例的类 JSON Pointer 路径。
   * @param errors 违规累积容器。
   */
  private static validateNode(
    schema: JsonValue, instance: JsonValue, path: string, errors: SchemaViolation[]): void {
    if (errors.length >= MAX_VIOLATIONS) {
      return;
    }
    // 布尔 Schema：true 恒通过，false 恒失败
    if (schema === true) {
      return;
    }
    if (schema === false) {
      JsonSchemaValidator.add(errors, path, 'false', 'schema-false');
      return;
    }
    // 非对象 Schema（理论上不出现于可信内置 Schema）视为无约束，跳过
    const node: Record<string, JsonValue> | undefined = JsonSchemaValidator.asObject(schema);
    if (node === undefined) {
      return;
    }

    JsonSchemaValidator.checkType(node, instance, path, errors);
    JsonSchemaValidator.checkConst(node, instance, path, errors);
    JsonSchemaValidator.checkEnum(node, instance, path, errors);
    JsonSchemaValidator.checkObject(node, instance, path, errors);
    JsonSchemaValidator.checkArray(node, instance, path, errors);
    JsonSchemaValidator.checkString(node, instance, path, errors);
    JsonSchemaValidator.checkNumber(node, instance, path, errors);
    JsonSchemaValidator.checkAllOf(node, instance, path, errors);
    JsonSchemaValidator.checkConditional(node, instance, path, errors);
    JsonSchemaValidator.warnUnknownKeywords(node);
  }

  /**
   * 校验 `type`（单类型字符串或类型字符串数组；支持 integer）。
   * @param node Schema 对象。
   * @param instance 实例值。
   * @param path 实例路径。
   * @param errors 违规容器。
   */
  private static checkType(
    node: Record<string, JsonValue>, instance: JsonValue, path: string, errors: SchemaViolation[]): void {
    // type 关键字原始值
    const typeValue: JsonValue | undefined = JsonSchemaValidator.get(node, 'type');
    if (typeValue === undefined) {
      return;
    }
    // 允许的类型名集合（单值归一为单元素数组）
    const typeNames: string[] = typeof typeValue === 'string'
      ? [typeValue]
      : JsonSchemaValidator.asStringArray(typeValue);
    if (typeNames.length === 0) {
      return;
    }
    // 是否命中任一允许类型
    let matched: boolean = false;
    for (let i: number = 0; i < typeNames.length; i++) {
      if (JsonSchemaValidator.matchesType(typeNames[i], instance)) {
        matched = true;
        break;
      }
    }
    if (!matched) {
      JsonSchemaValidator.add(errors, path, 'type',
        `expected=${typeNames.join('|')};actual=${JsonSchemaValidator.jsonTypeName(instance)}`);
    }
  }

  /**
   * 校验 `const`（实例须与常量深度相等）。
   * @param node Schema 对象。
   * @param instance 实例值。
   * @param path 实例路径。
   * @param errors 违规容器。
   */
  private static checkConst(
    node: Record<string, JsonValue>, instance: JsonValue, path: string, errors: SchemaViolation[]): void {
    if (!JsonSchemaValidator.has(node, 'const')) {
      return;
    }
    // 期望常量值
    const expected: JsonValue | undefined = JsonSchemaValidator.get(node, 'const');
    if (expected !== undefined && !JsonSchemaValidator.jsonEqual(instance, expected)) {
      JsonSchemaValidator.add(errors, path, 'const', 'const-mismatch');
    }
  }

  /**
   * 校验 `enum`（实例须与枚举项之一深度相等）。
   * @param node Schema 对象。
   * @param instance 实例值。
   * @param path 实例路径。
   * @param errors 违规容器。
   */
  private static checkEnum(
    node: Record<string, JsonValue>, instance: JsonValue, path: string, errors: SchemaViolation[]): void {
    // enum 候选数组
    const options: JsonValue[] | undefined = JsonSchemaValidator.asArray(JsonSchemaValidator.get(node, 'enum'));
    if (options === undefined) {
      return;
    }
    // 是否命中任一候选
    let matched: boolean = false;
    for (let i: number = 0; i < options.length; i++) {
      if (JsonSchemaValidator.jsonEqual(instance, options[i])) {
        matched = true;
        break;
      }
    }
    if (!matched) {
      JsonSchemaValidator.add(errors, path, 'enum', 'not-in-enum');
    }
  }

  /**
   * 校验对象类关键字：`required`、`minProperties`、`properties`、`additionalProperties`（仅当实例为对象）。
   * @param node Schema 对象。
   * @param instance 实例值。
   * @param path 实例路径。
   * @param errors 违规容器。
   */
  private static checkObject(
    node: Record<string, JsonValue>, instance: JsonValue, path: string, errors: SchemaViolation[]): void {
    // 实例对象（非对象则跳过对象类约束）
    const rec: Record<string, JsonValue> | undefined = JsonSchemaValidator.asObject(instance);
    if (rec === undefined) {
      return;
    }
    // 实例自有键集合
    const instanceKeys: string[] = Object.keys(rec);

    // required：逐个必填键必须存在
    const required: string[] = JsonSchemaValidator.asStringArray(JsonSchemaValidator.get(node, 'required'));
    for (let i: number = 0; i < required.length; i++) {
      if (instanceKeys.indexOf(required[i]) < 0) {
        JsonSchemaValidator.add(errors, path, 'required', `missing=${required[i]}`);
      }
    }

    // minProperties：属性数下限
    const minProps: number | undefined = JsonSchemaValidator.asNumber(JsonSchemaValidator.get(node, 'minProperties'));
    if (minProps !== undefined && instanceKeys.length < minProps) {
      JsonSchemaValidator.add(errors, path, 'minProperties', `min=${minProps};actual=${instanceKeys.length}`);
    }

    // properties：对每个已声明且存在的属性递归校验
    const props: Record<string, JsonValue> | undefined = JsonSchemaValidator.asObject(JsonSchemaValidator.get(node, 'properties'));
    // 已声明的属性名（用于 additionalProperties 判定）
    const declared: string[] = props !== undefined ? Object.keys(props) : [];
    if (props !== undefined) {
      for (let i: number = 0; i < declared.length; i++) {
        // 当前声明属性名
        const name: string = declared[i];
        if (instanceKeys.indexOf(name) >= 0) {
          JsonSchemaValidator.validateNode(props[name], rec[name],
            `${path}/${JsonSchemaValidator.escapePointer(name)}`, errors);
        }
      }
    }

    // additionalProperties：布尔或子 Schema，仅作用于未声明属性
    if (JsonSchemaValidator.has(node, 'additionalProperties')) {
      // additionalProperties 取值
      const ap: JsonValue | undefined = JsonSchemaValidator.get(node, 'additionalProperties');
      for (let i: number = 0; i < instanceKeys.length; i++) {
        // 当前实例属性名
        const key: string = instanceKeys[i];
        if (declared.indexOf(key) >= 0) {
          continue;
        }
        if (ap === false) {
          JsonSchemaValidator.add(errors, path, 'additionalProperties', `unexpected=${key}`);
        } else if (ap !== true && ap !== undefined) {
          JsonSchemaValidator.validateNode(ap, rec[key],
            `${path}/${JsonSchemaValidator.escapePointer(key)}`, errors);
        }
      }
    }
  }

  /**
   * 校验数组类关键字：`minItems`、`items`（仅当实例为数组）。
   * @param node Schema 对象。
   * @param instance 实例值。
   * @param path 实例路径。
   * @param errors 违规容器。
   */
  private static checkArray(
    node: Record<string, JsonValue>, instance: JsonValue, path: string, errors: SchemaViolation[]): void {
    if (!Array.isArray(instance)) {
      return;
    }
    // 实例数组
    const arr: JsonValue[] = instance as JsonValue[];

    // minItems：元素数下限
    const minItems: number | undefined = JsonSchemaValidator.asNumber(JsonSchemaValidator.get(node, 'minItems'));
    if (minItems !== undefined && arr.length < minItems) {
      JsonSchemaValidator.add(errors, path, 'minItems', `min=${minItems};actual=${arr.length}`);
    }

    // items：单一子 Schema，逐元素校验（本协议未用元组式 items 数组）
    if (JsonSchemaValidator.has(node, 'items')) {
      // items 子 Schema
      const itemSchema: JsonValue | undefined = JsonSchemaValidator.get(node, 'items');
      if (itemSchema !== undefined) {
        for (let i: number = 0; i < arr.length; i++) {
          JsonSchemaValidator.validateNode(itemSchema, arr[i], `${path}/${i}`, errors);
          if (errors.length >= MAX_VIOLATIONS) {
            break;
          }
        }
      }
    }
  }

  /**
   * 校验字符串类关键字：`minLength`、`pattern`（仅当实例为字符串）。
   * @param node Schema 对象。
   * @param instance 实例值。
   * @param path 实例路径。
   * @param errors 违规容器。
   */
  private static checkString(
    node: Record<string, JsonValue>, instance: JsonValue, path: string, errors: SchemaViolation[]): void {
    if (typeof instance !== 'string') {
      return;
    }
    // 实例字符串
    const text: string = instance;

    // minLength：按 Unicode 码点计数（与 JSON Schema 语义一致）
    const minLength: number | undefined = JsonSchemaValidator.asNumber(JsonSchemaValidator.get(node, 'minLength'));
    if (minLength !== undefined) {
      // 码点长度
      const codePoints: number = Array.from(text).length;
      if (codePoints < minLength) {
        JsonSchemaValidator.add(errors, path, 'minLength', `min=${minLength};actual=${codePoints}`);
      }
    }

    // pattern：ECMA-262 正则全文检索（内置 Schema 模式为可信、定锚的简单表达式）
    const pattern: string | undefined = JsonSchemaValidator.asString(JsonSchemaValidator.get(node, 'pattern'));
    if (pattern !== undefined) {
      try {
        // 编译后的正则
        const regex: RegExp = new RegExp(pattern);
        if (!regex.test(text)) {
          JsonSchemaValidator.add(errors, path, 'pattern', 'pattern-mismatch');
        }
      } catch (e) {
        // 内置 Schema 模式应始终可编译；不可编译属构建期缺陷，运行期不因此误判实例（跳过该断言）
      }
    }
  }

  /**
   * 校验数值类关键字：`minimum`、`maximum`（仅当实例为数值）。
   * @param node Schema 对象。
   * @param instance 实例值。
   * @param path 实例路径。
   * @param errors 违规容器。
   */
  private static checkNumber(
    node: Record<string, JsonValue>, instance: JsonValue, path: string, errors: SchemaViolation[]): void {
    if (typeof instance !== 'number') {
      return;
    }
    // 实例数值
    const value: number = instance;

    // minimum：下界（含端点）
    const minimum: number | undefined = JsonSchemaValidator.asNumber(JsonSchemaValidator.get(node, 'minimum'));
    if (minimum !== undefined && value < minimum) {
      JsonSchemaValidator.add(errors, path, 'minimum', `min=${minimum}`);
    }

    // maximum：上界（含端点）
    const maximum: number | undefined = JsonSchemaValidator.asNumber(JsonSchemaValidator.get(node, 'maximum'));
    if (maximum !== undefined && value > maximum) {
      JsonSchemaValidator.add(errors, path, 'maximum', `max=${maximum}`);
    }
  }

  /**
   * 校验 `allOf`：实例须满足全部子 Schema（路径不变）。
   * @param node Schema 对象。
   * @param instance 实例值。
   * @param path 实例路径。
   * @param errors 违规容器。
   */
  private static checkAllOf(
    node: Record<string, JsonValue>, instance: JsonValue, path: string, errors: SchemaViolation[]): void {
    // allOf 子 Schema 数组
    const subs: JsonValue[] | undefined = JsonSchemaValidator.asArray(JsonSchemaValidator.get(node, 'allOf'));
    if (subs === undefined) {
      return;
    }
    for (let i: number = 0; i < subs.length; i++) {
      JsonSchemaValidator.validateNode(subs[i], instance, path, errors);
    }
  }

  /**
   * 校验 `if`/`then`/`else`：实例满足 `if` 则须满足 `then`，否则须满足 `else`（`if` 自身违规不计入结果）。
   * @param node Schema 对象。
   * @param instance 实例值。
   * @param path 实例路径。
   * @param errors 违规容器。
   */
  private static checkConditional(
    node: Record<string, JsonValue>, instance: JsonValue, path: string, errors: SchemaViolation[]): void {
    if (!JsonSchemaValidator.has(node, 'if')) {
      return;
    }
    // if 条件 Schema
    const ifSchema: JsonValue | undefined = JsonSchemaValidator.get(node, 'if');
    if (ifSchema === undefined) {
      return;
    }
    // 条件是否成立（用独立容器评估，不污染主违规列表）
    const conditionMet: boolean = JsonSchemaValidator.validate(ifSchema, instance).length === 0;
    if (conditionMet) {
      if (JsonSchemaValidator.has(node, 'then')) {
        // then 分支 Schema
        const thenSchema: JsonValue | undefined = JsonSchemaValidator.get(node, 'then');
        if (thenSchema !== undefined) {
          JsonSchemaValidator.validateNode(thenSchema, instance, path, errors);
        }
      }
    } else if (JsonSchemaValidator.has(node, 'else')) {
      // else 分支 Schema
      const elseSchema: JsonValue | undefined = JsonSchemaValidator.get(node, 'else');
      if (elseSchema !== undefined) {
        JsonSchemaValidator.validateNode(elseSchema, instance, path, errors);
      }
    }
  }

  /**
   * 开发期防漏网：扫描节点中既非受支持断言、又非已知注解的关键字（仅用于自检，不影响校验结果）。
   * 当前不抛错；若未来 Schema 引入新关键字，应扩展引擎而非静默忽略约束。
   * @param node Schema 对象。
   */
  private static warnUnknownKeywords(node: Record<string, JsonValue>): void {
    // 引擎已显式处理的断言关键字
    const supported: string[] = [
      'type', 'const', 'enum', 'pattern', 'minLength',
      'minimum', 'maximum', 'properties', 'required', 'additionalProperties',
      'minProperties', 'items', 'minItems', 'allOf', 'if', 'then', 'else', 'format'
    ];
    // 本节点全部键
    const keys: string[] = Object.keys(node);
    for (let i: number = 0; i < keys.length; i++) {
      // 当前键名
      const key: string = keys[i];
      if (supported.indexOf(key) < 0 && ANNOTATION_KEYWORDS.indexOf(key) < 0) {
        // 未知关键字：内置 Schema 不应出现；此处不报违规，留待测试用例兜底发现
      }
    }
  }

  /**
   * 判断实例是否匹配指定 JSON Schema 类型名（含 `integer`）。
   * @param typeName 类型名（null/boolean/string/number/integer/array/object）。
   * @param instance 实例值。
   * @returns 匹配返回 true。
   */
  private static matchesType(typeName: string, instance: JsonValue): boolean {
    switch (typeName) {
      case 'null':
        return instance === null;
      case 'boolean':
        return typeof instance === 'boolean';
      case 'string':
        return typeof instance === 'string';
      case 'number':
        return typeof instance === 'number';
      case 'integer':
        return typeof instance === 'number' && Number.isInteger(instance);
      case 'array':
        return Array.isArray(instance);
      case 'object':
        return JsonSchemaValidator.asObject(instance) !== undefined;
      default:
        // 未知类型名：不作判定（避免误报）
        return true;
    }
  }

  /**
   * 取实例的 JSON 类型名（仅用于诊断 hint）。
   * @param instance 实例值。
   * @returns 类型名字符串。
   */
  private static jsonTypeName(instance: JsonValue): string {
    if (instance === null) {
      return 'null';
    }
    if (Array.isArray(instance)) {
      return 'array';
    }
    // typeof 结果（number/string/boolean/object）
    const t: string = typeof instance;
    return t === 'object' ? 'object' : t;
  }

  /**
   * 深度相等比较两个 JSON 值（用于 const/enum）。
   * @param a 左值。
   * @param b 右值。
   * @returns 相等返回 true。
   */
  private static jsonEqual(a: JsonValue, b: JsonValue): boolean {
    if (a === null || b === null) {
      return a === b;
    }
    // 数组对数组：长度 + 逐元素
    if (Array.isArray(a) && Array.isArray(b)) {
      // 左数组
      const arrA: JsonValue[] = a as JsonValue[];
      // 右数组
      const arrB: JsonValue[] = b as JsonValue[];
      if (arrA.length !== arrB.length) {
        return false;
      }
      for (let i: number = 0; i < arrA.length; i++) {
        if (!JsonSchemaValidator.jsonEqual(arrA[i], arrB[i])) {
          return false;
        }
      }
      return true;
    }
    // 对象对对象：键集合 + 逐键
    const objA: Record<string, JsonValue> | undefined = JsonSchemaValidator.asObject(a);
    const objB: Record<string, JsonValue> | undefined = JsonSchemaValidator.asObject(b);
    if (objA !== undefined && objB !== undefined) {
      // 左键集合
      const keysA: string[] = Object.keys(objA);
      // 右键集合
      const keysB: string[] = Object.keys(objB);
      if (keysA.length !== keysB.length) {
        return false;
      }
      for (let i: number = 0; i < keysA.length; i++) {
        // 当前键
        const key: string = keysA[i];
        if (keysB.indexOf(key) < 0 || !JsonSchemaValidator.jsonEqual(objA[key], objB[key])) {
          return false;
        }
      }
      return true;
    }
    // 其余（原始值，或类型不同）：严格相等
    return a === b;
  }

  /**
   * 安全取对象键值；键不存在返回 undefined（Record 静态不含 undefined，需显式按键存在判断）。
   * @param node Schema 或实例对象。
   * @param key 键名。
   * @returns 键值或 undefined。
   */
  private static get(node: Record<string, JsonValue>, key: string): JsonValue | undefined {
    return Object.keys(node).indexOf(key) >= 0 ? node[key] : undefined;
  }

  /**
   * 判断对象是否含某自有键。
   * @param node 对象。
   * @param key 键名。
   * @returns 含该键返回 true。
   */
  private static has(node: Record<string, JsonValue>, key: string): boolean {
    return Object.keys(node).indexOf(key) >= 0;
  }

  /**
   * 把 JSON 值视为对象（非 null、非数组的对象）；否则返回 undefined。
   * @param value JSON 值。
   * @returns 对象或 undefined。
   */
  private static asObject(value: JsonValue | undefined): Record<string, JsonValue> | undefined {
    if (value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value)) {
      return value as Record<string, JsonValue>;
    }
    return undefined;
  }

  /**
   * 把 JSON 值视为数组；否则返回 undefined。
   * @param value JSON 值。
   * @returns 数组或 undefined。
   */
  private static asArray(value: JsonValue | undefined): JsonValue[] | undefined {
    return Array.isArray(value) ? value as JsonValue[] : undefined;
  }

  /**
   * 把 JSON 值视为字符串；否则返回 undefined。
   * @param value JSON 值。
   * @returns 字符串或 undefined。
   */
  private static asString(value: JsonValue | undefined): string | undefined {
    return typeof value === 'string' ? value : undefined;
  }

  /**
   * 把 JSON 值视为数值；否则返回 undefined。
   * @param value JSON 值。
   * @returns 数值或 undefined。
   */
  private static asNumber(value: JsonValue | undefined): number | undefined {
    return typeof value === 'number' ? value : undefined;
  }

  /**
   * 把 JSON 值视为字符串数组（逐元素须为字符串）；非数组返回空数组。
   * @param value JSON 值。
   * @returns 字符串数组（可能为空）。
   */
  private static asStringArray(value: JsonValue | undefined): string[] {
    // 结果容器
    const result: string[] = [];
    if (!Array.isArray(value)) {
      return result;
    }
    // 输入数组
    const arr: JsonValue[] = value as JsonValue[];
    for (let i: number = 0; i < arr.length; i++) {
      // 当前元素
      const item: JsonValue = arr[i];
      if (typeof item === 'string') {
        result.push(item);
      }
    }
    return result;
  }

  /**
   * 转义 JSON Pointer 段（`~`→`~0`、`/`→`~1`），保证路径可读且无歧义。
   * @param segment 路径段（对象键名）。
   * @returns 转义后的段。
   */
  private static escapePointer(segment: string): string {
    return segment.split('~').join('~0').split('/').join('~1');
  }

  /**
   * 追加一条违规（受 MAX_VIOLATIONS 上限保护）。
   * @param errors 违规容器。
   * @param path 实例路径。
   * @param keyword 关键字。
   * @param hint 结构化原因（不含实例值）。
   */
  private static add(errors: SchemaViolation[], path: string, keyword: string, hint: string): void {
    if (errors.length < MAX_VIOLATIONS) {
      errors.push({ path: path.length > 0 ? path : '/', keyword: keyword, hint: hint });
    }
  }
}
