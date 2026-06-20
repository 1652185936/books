/**
 * ZIP 中央目录解析器（P1-1，LLD §2.4 step2「枚举条目，不解压即检查」）。
 *
 * 设计要点：
 * - **不解压**：只读取 ZIP 末尾的「中央目录结束记录（EOCD）」与「中央目录文件头」，
 *   据此枚举每个条目的相对路径、压缩前/后大小，供 `ZipSafetyValidator` 做安全校验。
 * - **以中央目录为准而非本地文件头**：本地头的大小字段可能延迟到数据描述符（flag bit 3），
 *   会被构造压缩炸弹者伪造为 0；中央目录中的大小字段是权威值，是检测炸弹的可信来源。
 * - **纯函数 / 无 SDK 依赖**：仅依赖 `Uint8Array` 与内置 UTF-8 解码（自带最小实现），
 *   既可在 ArkTS 运行，也便于离线单测；不引入 `@ohos.*`。
 * - **ZIP64 处理**：本第一版上限为「条目 ≤ 10,000、压缩包 ≤ 500 MB、解压 ≤ 2 GB」，
 *   均远小于 ZIP64 触发量级。一旦 EOCD 的条目数/偏移读到 ZIP64 哨兵值（0xFFFF/0xFFFFFFFF），
 *   说明真实量级已 ≥ 哨兵值、必然超出上限，直接判 `exceeds-zip64`（由校验器映射 IMP-003），
 *   无需展开完整 ZIP64 结构即可安全拒绝。
 *
 * 健壮性：所有越界/不一致一律归为 `malformed`（校验器映射 IMP-001），不抛裸异常、不越界读取。
 */

/** 单个 ZIP 条目（仅保留安全校验所需字段）。 */
export interface ZipEntry {
  /** 条目相对路径（ZIP 内部以 `/` 分隔，原样保留以便路径安全判定）。 */
  fileName: string;
  /** 压缩后大小（字节，来自中央目录头）。 */
  compressedSize: number;
  /** 压缩前（解压后）大小（字节，来自中央目录头）。 */
  uncompressedSize: number;
  /** 是否为目录条目（路径以 `/` 结尾）。 */
  isDirectory: boolean;
}

/** 解析失败原因：`not-a-zip`/`malformed`→IMP-001；`exceeds-zip64`→IMP-003。 */
export type ZipParseFailureReason = 'not-a-zip' | 'malformed' | 'exceeds-zip64';

/** 解析成功结果。 */
export interface ZipParseSuccess {
  /** 判别标记。 */
  ok: true;
  /** 枚举到的全部条目。 */
  entries: ZipEntry[];
}

/** 解析失败结果。 */
export interface ZipParseFailure {
  /** 判别标记。 */
  ok: false;
  /** 失败原因。 */
  reason: ZipParseFailureReason;
}

/** 解析结果（成功或失败的可判别联合）。 */
export type ZipParseResult = ZipParseSuccess | ZipParseFailure;

/** EOCD 记录签名 `PK\x05\x06`（小端 0x06054b50）。 */
const EOCD_SIGNATURE: number = 0x06054b50;
/** 中央目录文件头签名 `PK\x01\x02`（小端 0x02014b50）。 */
const CENTRAL_FILE_HEADER_SIGNATURE: number = 0x02014b50;
/** EOCD 固定部分长度（22 字节，不含注释）。 */
const EOCD_MIN_LENGTH: number = 22;
/** 中央目录文件头固定部分长度（46 字节，不含变长字段）。 */
const CENTRAL_HEADER_MIN_LENGTH: number = 46;
/** ZIP 注释最大长度（2 字节字段上限）。 */
const MAX_COMMENT_LENGTH: number = 0xffff;
/** uint16 哨兵值（ZIP64：真实条目数见 ZIP64 EOCD）。 */
const UINT16_SENTINEL: number = 0xffff;
/** uint32 哨兵值（ZIP64：真实大小/偏移见 ZIP64 扩展）。 */
const UINT32_SENTINEL: number = 0xffffffff;

/** ZIP 中央目录解析器（静态方法集合，风格对齐 `AppErrors`）。 */
export class ZipCentralDirectoryReader {
  /**
   * 解析 ZIP 字节缓冲，枚举全部条目（不解压）。
   * 入参应为完整压缩包字节（中央目录偏移按缓冲起点计），上层在校验前已用文件大小做前置约束。
   * @param bytes 完整 ZIP 字节缓冲。
   * @returns 解析结果（成功含条目数组，失败含原因）。
   */
  static read(bytes: Uint8Array): ZipParseResult {
    if (bytes.length < EOCD_MIN_LENGTH) {
      return { ok: false, reason: 'not-a-zip' };
    }
    // 定位 EOCD（从末尾向前在合理窗口内扫描签名）
    const eocdPos: number = ZipCentralDirectoryReader.findEocd(bytes);
    if (eocdPos < 0) {
      return { ok: false, reason: 'not-a-zip' };
    }
    // EOCD 字段：总条目数（offset 10，2B）、中央目录偏移（offset 16，4B）
    const totalEntries: number = ZipCentralDirectoryReader.readUint16(bytes, eocdPos + 10);
    const centralDirOffset: number = ZipCentralDirectoryReader.readUint32(bytes, eocdPos + 16);
    // ZIP64 哨兵：真实量级必然超过第一版上限，直接安全拒绝
    if (totalEntries === UINT16_SENTINEL || centralDirOffset === UINT32_SENTINEL) {
      return { ok: false, reason: 'exceeds-zip64' };
    }
    if (centralDirOffset >= bytes.length) {
      return { ok: false, reason: 'malformed' };
    }
    return ZipCentralDirectoryReader.readCentralDirectory(bytes, centralDirOffset, totalEntries);
  }

  /**
   * 从中央目录起点逐条读取文件头，组装条目数组。
   * @param bytes 完整 ZIP 字节缓冲。
   * @param startOffset 中央目录起始偏移。
   * @param totalEntries EOCD 声明的条目总数。
   * @returns 解析结果。
   */
  private static readCentralDirectory(
    bytes: Uint8Array, startOffset: number, totalEntries: number): ZipParseResult {
    // 累积条目
    const entries: ZipEntry[] = [];
    // 游标偏移
    let offset: number = startOffset;
    for (let i: number = 0; i < totalEntries; i++) {
      // 头部固定区必须完整
      if (offset + CENTRAL_HEADER_MIN_LENGTH > bytes.length) {
        return { ok: false, reason: 'malformed' };
      }
      if (ZipCentralDirectoryReader.readUint32(bytes, offset) !== CENTRAL_FILE_HEADER_SIGNATURE) {
        return { ok: false, reason: 'malformed' };
      }
      // 压缩后大小（offset 20）、压缩前大小（offset 24）
      const compressedSize: number = ZipCentralDirectoryReader.readUint32(bytes, offset + 20);
      const uncompressedSize: number = ZipCentralDirectoryReader.readUint32(bytes, offset + 24);
      // 变长字段长度：文件名（28）、扩展（30）、注释（32）
      const nameLength: number = ZipCentralDirectoryReader.readUint16(bytes, offset + 28);
      const extraLength: number = ZipCentralDirectoryReader.readUint16(bytes, offset + 30);
      const commentLength: number = ZipCentralDirectoryReader.readUint16(bytes, offset + 32);
      // 文件名起点与终点
      const nameStart: number = offset + CENTRAL_HEADER_MIN_LENGTH;
      const nameEnd: number = nameStart + nameLength;
      if (nameEnd > bytes.length) {
        return { ok: false, reason: 'malformed' };
      }
      // 解码文件名（中央目录路径以 `/` 分隔，原样保留供安全判定）
      const fileName: string = ZipCentralDirectoryReader.decodeUtf8(bytes, nameStart, nameLength);
      entries.push({
        fileName: fileName,
        compressedSize: compressedSize,
        uncompressedSize: uncompressedSize,
        isDirectory: fileName.length > 0 && fileName.charAt(fileName.length - 1) === '/'
      });
      // 推进到下一条文件头
      offset = nameEnd + extraLength + commentLength;
    }
    return { ok: true, entries: entries };
  }

  /**
   * 从缓冲末尾向前扫描 EOCD 签名，返回其起始偏移；未找到返回 -1。
   * 扫描窗口为「固定 22 字节 + 最大注释 0xFFFF」，覆盖合法 EOCD 的全部可能位置。
   * @param bytes 完整 ZIP 字节缓冲。
   * @returns EOCD 起始偏移，未找到为 -1。
   */
  private static findEocd(bytes: Uint8Array): number {
    // 扫描下界（不早于 0）
    const minPos: number = Math.max(0, bytes.length - (EOCD_MIN_LENGTH + MAX_COMMENT_LENGTH));
    for (let pos: number = bytes.length - EOCD_MIN_LENGTH; pos >= minPos; pos--) {
      if (ZipCentralDirectoryReader.readUint32(bytes, pos) === EOCD_SIGNATURE) {
        // 校验注释长度自洽：EOCD 起点 + 22 + 注释长度应等于缓冲长度
        const commentLength: number = ZipCentralDirectoryReader.readUint16(bytes, pos + 20);
        if (pos + EOCD_MIN_LENGTH + commentLength === bytes.length) {
          return pos;
        }
      }
    }
    return -1;
  }

  /**
   * 读取小端 uint16。
   * @param bytes 字节缓冲。
   * @param offset 起始偏移。
   * @returns 无符号 16 位整数。
   */
  private static readUint16(bytes: Uint8Array, offset: number): number {
    return (bytes[offset] | (bytes[offset + 1] << 8)) >>> 0;
  }

  /**
   * 读取小端 uint32（以无符号语义返回）。
   * @param bytes 字节缓冲。
   * @param offset 起始偏移。
   * @returns 无符号 32 位整数。
   */
  private static readUint32(bytes: Uint8Array, offset: number): number {
    return (bytes[offset]
      | (bytes[offset + 1] << 8)
      | (bytes[offset + 2] << 16)
      | (bytes[offset + 3] << 24)) >>> 0;
  }

  /**
   * 最小 UTF-8 解码（处理 1~4 字节序列）。非法字节以 U+FFFD 替换，保证不抛异常。
   * 自带实现以保持纯函数、不依赖 `@ohos.util.TextDecoder`，便于离线单测。
   * @param bytes 字节缓冲。
   * @param start 起始偏移。
   * @param length 字节数。
   * @returns 解码后的字符串。
   */
  private static decodeUtf8(bytes: Uint8Array, start: number, length: number): string {
    // 逐段拼接，避免大数组 apply 限制
    let result: string = '';
    // 当前读取位置
    let i: number = start;
    // 终止位置
    const end: number = start + length;
    while (i < end) {
      // 首字节
      const b0: number = bytes[i];
      if (b0 < 0x80) {
        result += String.fromCharCode(b0);
        i += 1;
      } else if (b0 >= 0xc0 && b0 < 0xe0 && i + 1 < end) {
        // 2 字节序列
        const cp: number = ((b0 & 0x1f) << 6) | (bytes[i + 1] & 0x3f);
        result += String.fromCharCode(cp);
        i += 2;
      } else if (b0 >= 0xe0 && b0 < 0xf0 && i + 2 < end) {
        // 3 字节序列
        const cp: number = ((b0 & 0x0f) << 12) | ((bytes[i + 1] & 0x3f) << 6) | (bytes[i + 2] & 0x3f);
        result += String.fromCharCode(cp);
        i += 3;
      } else if (b0 >= 0xf0 && b0 < 0xf8 && i + 3 < end) {
        // 4 字节序列（基本多文种平面外，使用码点构造）
        const cp: number = ((b0 & 0x07) << 18)
          | ((bytes[i + 1] & 0x3f) << 12)
          | ((bytes[i + 2] & 0x3f) << 6)
          | (bytes[i + 3] & 0x3f);
        result += String.fromCodePoint(cp);
        i += 4;
      } else {
        // 非法/截断字节，以替换符占位并前进 1
        result += String.fromCharCode(0xfffd);
        i += 1;
      }
    }
    return result;
  }
}
