/**
 * SQL 脚本切分工具（P0-3，LLD §3）。
 *
 * 迁移文件（如 `V001__initial.sql`）是多语句脚本，而 `relationalStore.executeSql`
 * 一次只执行一条语句，故执行前需把脚本切分为单语句数组。
 *
 * 切分约定（与迁移 SQL 文件头部声明一致，二者必须同步）：
 * 1. `--` 起始为行注释，截断至行尾；
 * 2. 语句以分号 `;` 分隔；
 * 3. 任何字符串字面量内均不得包含 `;` 或 `--`，使「去注释 → 按 `;` 切分」无歧义。
 *
 * 该切分逻辑已在 SQLite（relationalStore 底座）上对 V001 全量验证通过。
 */
export class SqlScript {
  /**
   * 将多语句 SQL 文本切分为单条可执行语句数组。
   * @param script 原始 SQL 脚本文本（含 `--` 行注释，语句以 `;` 分隔）。
   * @returns 去注释、去首尾空白后的非空单语句数组（不含结尾 `;`）。
   */
  static splitStatements(script: string): string[] {
    // 逐行剥离 `--` 行注释（约定：字符串字面量内不含 `--`）
    const withoutComments: string = script
      .split('\n')
      .map((line: string): string => {
        // 当前行 `--` 出现位置；-1 表示无注释
        const commentIndex: number = line.indexOf('--');
        return commentIndex >= 0 ? line.substring(0, commentIndex) : line;
      })
      .join('\n');
    // 按 `;` 切分后清洗（约定：字符串字面量内不含 `;`）
    return withoutComments
      .split(';')
      .map((statement: string): string => statement.trim())
      .filter((statement: string): boolean => statement.length > 0);
  }
}
