-- =============================================================================
-- 墨学书架 数据库初始迁移 V001__initial.sql
-- 真值来源：《03-详细设计说明书》§3.3~§3.25（表/列/约束/索引）；
--           字段级映射以《06-协议到数据库映射规范》为准；跨模块 DTO 以《04 契约》为准。
-- 约束口径：枚举列一律 TEXT NOT NULL CHECK(IN(...))（LLD §1.3 / R-039：NULL 会穿透 CHECK）；
--           时间列 INTEGER（UTC epoch ms，LLD §1.3）；布尔列 INTEGER CHECK(IN(0,1))。
-- 本文件不创建 db_meta / schema_migrations：这两张元数据表由迁移执行器在迁移前
--   以 CREATE TABLE IF NOT EXISTS 引导建立（§3.2 必需键由执行器写入）。
-- 语句分隔约定：每条 DDL 以分号 `;` 结尾；`--` 行注释；任何字符串字面量内均不含 `;` 或 `--`，
--   故迁移执行器可安全地「去注释→按 `;` 切分」逐条执行（见 SqlScript.splitSqlStatements）。
-- 外键说明：运行期需 `PRAGMA foreign_keys=ON`（由 Database 封装开启）；建表顺序已保证
--   被引用表先于引用表创建（assets 先于 content_blocks、review_cards 先于 handwriting_records 等）。
-- =============================================================================

-- §3.3 books -----------------------------------------------------------------
CREATE TABLE books (
  id                TEXT    NOT NULL PRIMARY KEY,
  package_id        TEXT    NOT NULL,
  content_version   TEXT    NOT NULL,
  format_version    TEXT    NOT NULL,
  title             TEXT    NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
  subtitle          TEXT    NOT NULL DEFAULT '',
  authors_json      TEXT    NOT NULL DEFAULT '[]',
  description       TEXT    NOT NULL DEFAULT '',
  languages_json    TEXT    NOT NULL DEFAULT '[]',
  cover_path        TEXT,
  chapter_count     INTEGER NOT NULL CHECK (chapter_count >= 1),
  source_page_count INTEGER          CHECK (source_page_count IS NULL OR source_page_count > 0),
  source_is_scanned INTEGER NOT NULL CHECK (source_is_scanned IN (0, 1)),
  status            TEXT    NOT NULL CHECK (status IN ('ready', 'updating', 'broken', 'deleted')),
  imported_at       INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL,
  last_opened_at    INTEGER,
  deleted_at        INTEGER,
  UNIQUE (package_id, content_version)
);
CREATE INDEX idx_books_status      ON books (status);
CREATE INDEX idx_books_last_opened ON books (last_opened_at DESC);
CREATE INDEX idx_books_title       ON books (title);

-- §3.7 assets（先于 content_blocks 创建，供其 asset_id 外键引用）---------------
CREATE TABLE assets (
  id            TEXT    NOT NULL PRIMARY KEY,
  book_id       TEXT    NOT NULL REFERENCES books (id) ON DELETE CASCADE,
  relative_path TEXT    NOT NULL,
  local_path    TEXT    NOT NULL,
  media_type    TEXT    NOT NULL CHECK (media_type IN ('image/webp', 'image/png', 'image/jpeg')),
  sha256        TEXT    NOT NULL CHECK (length(sha256) = 64),
  size_bytes    INTEGER NOT NULL CHECK (size_bytes >= 0),
  width_px      INTEGER          CHECK (width_px IS NULL OR width_px > 0),
  height_px     INTEGER          CHECK (height_px IS NULL OR height_px > 0),
  alt_text      TEXT    NOT NULL DEFAULT '',
  UNIQUE (book_id, relative_path)
);

-- §3.4 chapters --------------------------------------------------------------
CREATE TABLE chapters (
  id                TEXT    NOT NULL PRIMARY KEY,
  book_id           TEXT    NOT NULL REFERENCES books (id) ON DELETE CASCADE,
  external_id       TEXT    NOT NULL,
  order_no          INTEGER NOT NULL CHECK (order_no >= 1),
  kind              TEXT    NOT NULL CHECK (kind IN ('lesson', 'review', 'appendix', 'answer-key', 'index')),
  title             TEXT    NOT NULL,
  title_zh          TEXT    NOT NULL DEFAULT '',
  estimated_minutes INTEGER NOT NULL DEFAULT 1 CHECK (estimated_minutes >= 1),
  source_pages_json TEXT    NOT NULL,
  content_file      TEXT    NOT NULL,
  content_hash      TEXT    NOT NULL CHECK (length(content_hash) = 64),
  review_status     TEXT    NOT NULL DEFAULT 'unreviewed' CHECK (review_status IN ('unreviewed', 'needs-review', 'reviewed')),
  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL,
  UNIQUE (book_id, external_id),
  UNIQUE (book_id, order_no)
);
CREATE INDEX idx_chapters_book_kind_order ON chapters (book_id, kind, order_no);

-- §3.5 sections --------------------------------------------------------------
CREATE TABLE sections (
  id                TEXT    NOT NULL PRIMARY KEY,
  chapter_id        TEXT    NOT NULL REFERENCES chapters (id) ON DELETE CASCADE,
  external_id       TEXT    NOT NULL,
  order_no          INTEGER NOT NULL CHECK (order_no >= 1),
  type              TEXT    NOT NULL CHECK (type IN ('concept', 'rule', 'examples', 'comparison', 'spelling', 'note', 'illustration', 'summary')),
  title             TEXT    NOT NULL DEFAULT '',
  source_pages_json TEXT    NOT NULL,
  confidence        REAL    NOT NULL CHECK (confidence BETWEEN 0 AND 1),
  UNIQUE (chapter_id, external_id),
  UNIQUE (chapter_id, order_no)
);

-- §3.6 content_blocks --------------------------------------------------------
CREATE TABLE content_blocks (
  id                TEXT    NOT NULL PRIMARY KEY,
  section_id        TEXT    NOT NULL REFERENCES sections (id) ON DELETE CASCADE,
  external_id       TEXT,
  order_no          INTEGER NOT NULL CHECK (order_no >= 1),
  type              TEXT    NOT NULL,
  payload_json      TEXT    NOT NULL,
  plain_text        TEXT    NOT NULL DEFAULT '',
  asset_id          TEXT             REFERENCES assets (id) ON DELETE SET NULL,
  source_pages_json TEXT    NOT NULL,
  UNIQUE (section_id, order_no)
);
CREATE INDEX idx_content_blocks_section_order ON content_blocks (section_id, order_no);

-- §3.8 exercises（题型 CHECK 含全部九种，R-063；非手写四种导入保留、交互后续迭代）-----
CREATE TABLE exercises (
  id                   TEXT    NOT NULL PRIMARY KEY,
  chapter_id           TEXT    NOT NULL REFERENCES chapters (id) ON DELETE CASCADE,
  external_id          TEXT    NOT NULL,
  order_no             INTEGER NOT NULL CHECK (order_no >= 1),
  type                 TEXT    NOT NULL CHECK (type IN (
                         'fill-blank-handwriting', 'multi-blank-handwriting',
                         'rewrite-sentence-handwriting', 'short-answer-handwriting',
                         'choice', 'true-false', 'match', 'order-words',
                         'correction-handwriting')),
  instruction          TEXT    NOT NULL DEFAULT '',
  prompt_json          TEXT    NOT NULL,
  context_json         TEXT    NOT NULL DEFAULT '{}',
  feedback_json        TEXT    NOT NULL DEFAULT '{}',
  grading_options_json TEXT    NOT NULL DEFAULT '{}',
  source_ref_json      TEXT    NOT NULL,
  answer_source        TEXT    NOT NULL CHECK (answer_source IN ('answer-key', 'explicit-in-page', 'ai-inferred', 'manual')),
  confidence           REAL    NOT NULL CHECK (confidence BETWEEN 0 AND 1),
  enabled              INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
  allow_empty          INTEGER NOT NULL DEFAULT 0 CHECK (allow_empty IN (0, 1)),
  UNIQUE (chapter_id, external_id),
  UNIQUE (chapter_id, order_no)
);

-- §3.9 exercise_blanks -------------------------------------------------------
CREATE TABLE exercise_blanks (
  id               TEXT    NOT NULL PRIMARY KEY,
  exercise_id      TEXT    NOT NULL REFERENCES exercises (id) ON DELETE CASCADE,
  blank_key        TEXT    NOT NULL,
  order_no         INTEGER NOT NULL CHECK (order_no >= 1),
  width_em         REAL    NOT NULL CHECK (width_em BETWEEN 3 AND 40),
  lines            INTEGER NOT NULL DEFAULT 1 CHECK (lines BETWEEN 1 AND 5),
  handwriting_mode TEXT    NOT NULL DEFAULT 'english' CHECK (handwriting_mode IN ('english', 'number', 'mixed')),
  display_answer   TEXT    NOT NULL,
  tokens_json      TEXT    NOT NULL DEFAULT '[]',
  UNIQUE (exercise_id, blank_key),
  UNIQUE (exercise_id, order_no)
);

-- §3.10 accepted_answers（去重后入库，R-040；每空至多一个主答案由部分唯一索引兜底）-----
CREATE TABLE accepted_answers (
  id                TEXT    NOT NULL PRIMARY KEY,
  blank_id          TEXT    NOT NULL REFERENCES exercise_blanks (id) ON DELETE CASCADE,
  normalized_answer TEXT    NOT NULL,
  display_answer    TEXT    NOT NULL,
  is_primary        INTEGER NOT NULL CHECK (is_primary IN (0, 1)),
  sort_order        INTEGER NOT NULL DEFAULT 1,
  UNIQUE (blank_id, normalized_answer)
);
CREATE UNIQUE INDEX idx_accepted_answers_primary ON accepted_answers (blank_id) WHERE is_primary = 1;

-- §3.11 grading_rules（blank_id 为已声明可空外键，LLD §1.3 例外）------------------
CREATE TABLE grading_rules (
  id           TEXT    NOT NULL PRIMARY KEY,
  exercise_id  TEXT    NOT NULL REFERENCES exercises (id) ON DELETE CASCADE,
  blank_id     TEXT             REFERENCES exercise_blanks (id) ON DELETE CASCADE,
  priority     INTEGER NOT NULL CHECK (priority >= 0),
  rule_type    TEXT    NOT NULL CHECK (rule_type IN ('exact', 'tokens-equal', 'missing-token', 'regex', 'custom-code')),
  params_json  TEXT    NOT NULL,
  result       TEXT    NOT NULL CHECK (result IN ('correct', 'partial', 'incorrect')),
  feedback_code TEXT   NOT NULL,
  feedback_zh  TEXT    NOT NULL,
  UNIQUE (exercise_id, priority, id)
);

-- §3.12 reading_progress -----------------------------------------------------
CREATE TABLE reading_progress (
  book_id            TEXT    NOT NULL REFERENCES books (id) ON DELETE CASCADE,
  chapter_id         TEXT    NOT NULL REFERENCES chapters (id) ON DELETE CASCADE,
  status             TEXT    NOT NULL DEFAULT 'not-started' CHECK (status IN ('not-started', 'learning', 'completed', 'review-due')),
  completion_percent REAL    NOT NULL CHECK (completion_percent BETWEEN 0 AND 100),
  last_section_id    TEXT             REFERENCES sections (id) ON DELETE SET NULL,
  last_block_id      TEXT             REFERENCES content_blocks (id) ON DELETE SET NULL,
  scroll_anchor_json TEXT    NOT NULL DEFAULT '{}',
  first_opened_at    INTEGER,
  last_opened_at     INTEGER,
  completed_at       INTEGER,
  PRIMARY KEY (book_id, chapter_id)
);
CREATE INDEX idx_reading_progress_book_opened ON reading_progress (book_id, last_opened_at DESC);

-- §3.12A section_progress（Sr 权威来源）----------------------------------------
CREATE TABLE section_progress (
  book_id           TEXT    NOT NULL REFERENCES books (id) ON DELETE CASCADE,
  chapter_id        TEXT    NOT NULL REFERENCES chapters (id) ON DELETE CASCADE,
  section_id        TEXT    NOT NULL PRIMARY KEY REFERENCES sections (id) ON DELETE CASCADE,
  is_read           INTEGER NOT NULL DEFAULT 0 CHECK (is_read IN (0, 1)),
  max_visible_ratio REAL    NOT NULL DEFAULT 0 CHECK (max_visible_ratio BETWEEN 0 AND 1),
  active_duration_ms INTEGER NOT NULL DEFAULT 0 CHECK (active_duration_ms >= 0),
  first_opened_at   INTEGER,
  read_at           INTEGER,
  updated_at        INTEGER NOT NULL,
  UNIQUE (chapter_id, section_id)
);

-- §3.13 learning_events ------------------------------------------------------
CREATE TABLE learning_events (
  id           TEXT    NOT NULL PRIMARY KEY,
  book_id      TEXT    NOT NULL REFERENCES books (id) ON DELETE CASCADE,
  chapter_id   TEXT             REFERENCES chapters (id) ON DELETE SET NULL,
  event_type   TEXT    NOT NULL,
  event_at     INTEGER NOT NULL,
  duration_ms  INTEGER NOT NULL DEFAULT 0 CHECK (duration_ms >= 0),
  payload_json TEXT    NOT NULL DEFAULT '{}'
);
CREATE INDEX idx_learning_events_at      ON learning_events (event_at);
CREATE INDEX idx_learning_events_book_at ON learning_events (book_id, event_at);

-- §3.14 exercise_attempts（recognition_error_code 形式化 CHECK，R-057）-----------
CREATE TABLE exercise_attempts (
  id                     TEXT    NOT NULL PRIMARY KEY,
  exercise_id            TEXT    NOT NULL REFERENCES exercises (id) ON DELETE CASCADE,
  book_id                TEXT    NOT NULL REFERENCES books (id) ON DELETE CASCADE,
  chapter_id             TEXT    NOT NULL REFERENCES chapters (id) ON DELETE CASCADE,
  started_at             INTEGER NOT NULL,
  submitted_at           INTEGER,
  recognized_text_json   TEXT    NOT NULL DEFAULT '{}',
  normalized_text_json   TEXT    NOT NULL DEFAULT '{}',
  recognition_status     TEXT    NOT NULL DEFAULT 'not-requested' CHECK (recognition_status IN ('not-requested', 'processing', 'succeeded', 'failed')),
  grade                  TEXT    NOT NULL DEFAULT 'draft' CHECK (grade IN ('draft', 'correct', 'partial', 'incorrect', 'recognition-failed')),
  score                  REAL             CHECK (score IS NULL OR score BETWEEN 0 AND 1),
  feedback_code          TEXT,
  duration_ms            INTEGER NOT NULL DEFAULT 0 CHECK (duration_ms >= 0),
  recognition_model      TEXT    NOT NULL DEFAULT '',
  recognition_error_code TEXT             CHECK (recognition_error_code IS NULL OR recognition_error_code IN ('timeout', 'empty-text', 'service-unavailable', 'unsupported-mode', 'internal-error')),
  blank_results_json     TEXT    NOT NULL DEFAULT '[]'
);
CREATE INDEX idx_attempts_exercise_submitted ON exercise_attempts (exercise_id, submitted_at DESC);
CREATE INDEX idx_attempts_book_submitted     ON exercise_attempts (book_id, submitted_at DESC);
CREATE INDEX idx_attempts_grade              ON exercise_attempts (grade);

-- §3.16 notes（软删除 deleted_at；笔迹物理生命周期绑定属主物理删除，R-041）----------
CREATE TABLE notes (
  id               TEXT    NOT NULL PRIMARY KEY,
  book_id          TEXT    NOT NULL REFERENCES books (id) ON DELETE CASCADE,
  chapter_id       TEXT    NOT NULL REFERENCES chapters (id) ON DELETE CASCADE,
  section_id       TEXT             REFERENCES sections (id) ON DELETE SET NULL,
  block_id         TEXT             REFERENCES content_blocks (id) ON DELETE SET NULL,
  type             TEXT    NOT NULL CHECK (type IN ('handwriting', 'text')),
  text_content     TEXT    NOT NULL DEFAULT '',
  anchor_json      TEXT    NOT NULL,
  color            TEXT    NOT NULL DEFAULT '#2F65A4',
  relocation_state TEXT    NOT NULL DEFAULT 'stable' CHECK (relocation_state IN ('stable', 'needs-relocation', 'orphaned')),
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL,
  deleted_at       INTEGER
);

-- §3.19 review_cards（先于 handwriting_records 创建，供其 review_card_id 外键引用）----
CREATE TABLE review_cards (
  id               TEXT    NOT NULL PRIMARY KEY,
  book_id          TEXT    NOT NULL REFERENCES books (id) ON DELETE CASCADE,
  chapter_id       TEXT    NOT NULL REFERENCES chapters (id) ON DELETE CASCADE,
  source_type      TEXT    NOT NULL CHECK (source_type IN ('package', 'wrong-item')),
  source_id        TEXT    NOT NULL,
  front_json       TEXT    NOT NULL,
  back_json        TEXT    NOT NULL,
  state            TEXT    NOT NULL CHECK (state IN ('new', 'learning', 'review', 'suspended')),
  ease_factor      REAL    NOT NULL DEFAULT 2.5 CHECK (ease_factor BETWEEN 1.3 AND 3.5),
  interval_days    INTEGER NOT NULL DEFAULT 0 CHECK (interval_days >= 0),
  due_at           INTEGER NOT NULL,
  last_reviewed_at INTEGER,
  lapses           INTEGER NOT NULL DEFAULT 0 CHECK (lapses >= 0),
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL,
  UNIQUE (source_type, source_id)
);
CREATE INDEX idx_review_cards_state_due ON review_cards (state, due_at);

-- §3.20 review_logs ----------------------------------------------------------
CREATE TABLE review_logs (
  id                TEXT    NOT NULL PRIMARY KEY,
  card_id           TEXT    NOT NULL REFERENCES review_cards (id) ON DELETE CASCADE,
  rating            INTEGER NOT NULL CHECK (rating BETWEEN 0 AND 3),
  reviewed_at       INTEGER NOT NULL,
  response_ms       INTEGER NOT NULL CHECK (response_ms >= 0),
  previous_interval INTEGER NOT NULL CHECK (previous_interval >= 0),
  next_interval     INTEGER NOT NULL CHECK (next_interval >= 0),
  previous_ease     REAL    NOT NULL,
  next_ease         REAL    NOT NULL
);
CREATE INDEX idx_review_logs_card_reviewed ON review_logs (card_id, reviewed_at DESC);

-- §3.15 handwriting_records（三态互斥 XOR + target_type 对应 CHECK，R-041）---------
CREATE TABLE handwriting_records (
  id             TEXT    NOT NULL PRIMARY KEY,
  attempt_id     TEXT             REFERENCES exercise_attempts (id) ON DELETE CASCADE,
  note_id        TEXT             REFERENCES notes (id) ON DELETE CASCADE,
  review_card_id TEXT             REFERENCES review_cards (id) ON DELETE CASCADE,
  target_type    TEXT    NOT NULL CHECK (target_type IN ('exercise-blank', 'note', 'review-answer')),
  target_id      TEXT    NOT NULL,
  stroke_path    TEXT    NOT NULL,
  preview_path   TEXT,
  canvas_width   REAL    NOT NULL CHECK (canvas_width > 0),
  canvas_height  REAL    NOT NULL CHECK (canvas_height > 0),
  pen_color      TEXT    NOT NULL,
  pen_width      REAL    NOT NULL CHECK (pen_width BETWEEN 0.5 AND 20),
  stroke_count   INTEGER NOT NULL CHECK (stroke_count >= 0),
  point_count    INTEGER NOT NULL CHECK (point_count >= 0),
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL,
  CHECK ((attempt_id IS NOT NULL) + (note_id IS NOT NULL) + (review_card_id IS NOT NULL) = 1),
  CHECK (
    (target_type = 'exercise-blank' AND attempt_id IS NOT NULL)
    OR (target_type = 'note' AND note_id IS NOT NULL)
    OR (target_type = 'review-answer' AND review_card_id IS NOT NULL)
  )
);

-- §3.17 highlights（range_end ≤ 保存时 plain_text 长度由应用层保证，跨表无法 CHECK）---
CREATE TABLE highlights (
  id               TEXT    NOT NULL PRIMARY KEY,
  book_id          TEXT    NOT NULL REFERENCES books (id) ON DELETE CASCADE,
  chapter_id       TEXT    NOT NULL REFERENCES chapters (id) ON DELETE CASCADE,
  block_id         TEXT    NOT NULL REFERENCES content_blocks (id) ON DELETE CASCADE,
  range_start      INTEGER NOT NULL CHECK (range_start >= 0),
  range_end        INTEGER NOT NULL CHECK (range_end > range_start),
  quote_text       TEXT    NOT NULL,
  color            TEXT    NOT NULL,
  relocation_state TEXT    NOT NULL DEFAULT 'stable' CHECK (relocation_state IN ('stable', 'needs-relocation', 'orphaned')),
  created_at       INTEGER NOT NULL,
  deleted_at       INTEGER
);

-- §3.18 bookmarks（块级/章节级各自部分唯一索引，R-012）---------------------------
CREATE TABLE bookmarks (
  id         TEXT    NOT NULL PRIMARY KEY,
  book_id    TEXT    NOT NULL REFERENCES books (id) ON DELETE CASCADE,
  chapter_id TEXT    NOT NULL REFERENCES chapters (id) ON DELETE CASCADE,
  block_id   TEXT             REFERENCES content_blocks (id) ON DELETE SET NULL,
  scope      TEXT    NOT NULL CHECK (scope IN ('chapter', 'block')),
  label      TEXT    NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX idx_bookmarks_block   ON bookmarks (book_id, chapter_id, block_id) WHERE scope = 'block';
CREATE UNIQUE INDEX idx_bookmarks_chapter ON bookmarks (book_id, chapter_id) WHERE scope = 'chapter';

-- §3.21 wrong_items（error_type 受控词表 CHECK；当前汇总，历史以 attempts 为准）-------
CREATE TABLE wrong_items (
  id                TEXT    NOT NULL PRIMARY KEY,
  exercise_id       TEXT    NOT NULL REFERENCES exercises (id) ON DELETE CASCADE,
  first_attempt_id  TEXT             REFERENCES exercise_attempts (id),
  latest_attempt_id TEXT             REFERENCES exercise_attempts (id),
  error_type        TEXT    NOT NULL CHECK (error_type IN (
                      'missing-auxiliary', 'wrong-tense', 'wrong-form', 'spelling',
                      'missing-word', 'extra-word', 'word-order', 'recognition-uncertain', 'other')),
  error_count       INTEGER NOT NULL DEFAULT 1 CHECK (error_count >= 1),
  correct_streak    INTEGER NOT NULL DEFAULT 0 CHECK (correct_streak >= 0),
  status            TEXT    NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'mastered', 'dismissed')),
  next_due_at       INTEGER,
  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL,
  UNIQUE (exercise_id)
);

-- §3.22 import_jobs（不保存原 URI，仅 URI 哈希；error_detail ≤1000）----------------
CREATE TABLE import_jobs (
  id              TEXT    NOT NULL PRIMARY KEY,
  source_name     TEXT    NOT NULL,
  source_size     INTEGER NOT NULL CHECK (source_size >= 0),
  source_uri_hash TEXT    NOT NULL,
  package_id      TEXT,
  state           TEXT    NOT NULL,
  current_stage   TEXT    NOT NULL,
  progress        REAL    NOT NULL CHECK (progress BETWEEN 0 AND 1),
  warning_count   INTEGER NOT NULL DEFAULT 0,
  error_code      TEXT,
  error_detail    TEXT             CHECK (error_detail IS NULL OR length(error_detail) <= 1000),
  started_at      INTEGER NOT NULL,
  completed_at    INTEGER
);

-- §3.23 package_files --------------------------------------------------------
CREATE TABLE package_files (
  import_job_id    TEXT    NOT NULL REFERENCES import_jobs (id) ON DELETE CASCADE,
  relative_path    TEXT    NOT NULL,
  expected_sha256  TEXT,
  actual_sha256    TEXT,
  size_bytes       INTEGER NOT NULL CHECK (size_bytes >= 0),
  validation_state TEXT    NOT NULL DEFAULT 'pending' CHECK (validation_state IN ('pending', 'valid', 'warning', 'invalid')),
  error_code       TEXT,
  PRIMARY KEY (import_job_id, relative_path)
);

-- §3.24 user_settings --------------------------------------------------------
CREATE TABLE user_settings (
  key        TEXT    NOT NULL PRIMARY KEY,
  value_json TEXT    NOT NULL,
  updated_at INTEGER NOT NULL
);

-- §3.25 content_review_flags（reviewQueue[] 落库，R-008）-------------------------
CREATE TABLE content_review_flags (
  id                  TEXT    NOT NULL PRIMARY KEY,
  book_id             TEXT    NOT NULL REFERENCES books (id) ON DELETE CASCADE,
  chapter_external_id TEXT    NOT NULL,
  json_path           TEXT    NOT NULL DEFAULT '',
  severity            TEXT    NOT NULL CHECK (severity IN ('low', 'medium', 'high')),
  type                TEXT    NOT NULL,
  message             TEXT    NOT NULL DEFAULT '',
  created_at          INTEGER NOT NULL
);
CREATE INDEX idx_content_review_flags_book_chapter ON content_review_flags (book_id, chapter_external_id);
