-- =====================================================================
-- daily_routine：作息打卡数据库（MySQL 8.0+，已在 8.4 上测试）
--
-- 表
--   task      事项表：事项名称和类别，约 25 行，基本不变
--   schedule  作息表：工作日/周末几点做什么、计划多少分钟、从哪天开始生效
--   checkin   打卡表：每天每一项的完成情况，只有打过卡的项才有记录
--
-- 视图
--   v_daily_plan    每天应该做的所有事项（由作息表展开，含未打卡的项）
--   v_daily_stats   每日指标：完成率、学习完成率、未打卡数、补打卡数等
--   v_weekly_stats  每周指标（周一到周日）
--
-- 说明
--   只有学习时间需要打卡（schedule.count_in_rate = 1），包括科研学习和复盘、规划（类别 study、plan）；
--   休息、用餐、洗漱等非学习时间不需要打卡，
--   也不计入完成率和学习完成率。
--   统计指标不单独建表，全部由视图实时计算，补打卡后自动更新。
--   逻辑外键（不建数据库强制外键，由程序保证；事项和作息只停用、不删除）：
--     schedule.task_id     → task.id
--     checkin.schedule_id  → schedule.id
--
-- 导入方法
--   mysql -u 你的用户名 -p < daily_routine.sql
--   注意：脚本会删除并重建 daily_routine 库里的这几张表和视图。
-- =====================================================================

-- 按 utf8mb4 读取本脚本，否则中文会被导成乱码
SET NAMES utf8mb4;

CREATE DATABASE IF NOT EXISTS daily_routine
  DEFAULT CHARACTER SET utf8mb4
  DEFAULT COLLATE utf8mb4_unicode_ci;

USE daily_routine;

DROP VIEW  IF EXISTS v_weekly_stats;
DROP VIEW  IF EXISTS v_daily_stats;
DROP VIEW  IF EXISTS v_daily_plan;
DROP TABLE IF EXISTS checkin;
DROP TABLE IF EXISTS schedule;
DROP TABLE IF EXISTS task;
DROP TABLE IF EXISTS schema_migrations;

-- ---------------------------------------------------------------------
-- 0. 已执行的数据库变更（后端启动时自动执行 migrations/ 里还没执行过的 .sql）
--    本脚本已经包含的变更，在文件末尾登记，新装时不会重复执行。
-- ---------------------------------------------------------------------
CREATE TABLE schema_migrations (
  name        VARCHAR(200) NOT NULL PRIMARY KEY,
  applied_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB COMMENT='已执行的数据库变更';

-- ---------------------------------------------------------------------
-- 1. 事项表
--    改名只用于修正笔误；换了新事项请新增一行，不要改旧行的含义。
-- ---------------------------------------------------------------------
CREATE TABLE task (
  id          INT UNSIGNED  NOT NULL AUTO_INCREMENT              COMMENT '事项编号',
  name        VARCHAR(50)   NOT NULL                             COMMENT '事项名',
  category    VARCHAR(10)   NOT NULL                             COMMENT '类别：study 学习 / plan 计划复盘 / rest 休息 / meal 用餐 / fun 娱乐 / life 起居 / sleep 睡眠',
  is_active   TINYINT(1)    NOT NULL DEFAULT 1                   COMMENT '1 在用，0 停用',
  created_at  DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP   COMMENT '创建时间',
  PRIMARY KEY (id),
  UNIQUE KEY uk_task_name (name),
  CONSTRAINT ck_task_category CHECK (category IN ('study','plan','rest','meal','fun','life','sleep')),
  CONSTRAINT ck_task_active   CHECK (is_active IN (0,1))
) ENGINE=InnoDB COMMENT='事项表';

-- ---------------------------------------------------------------------
-- 2. 作息表
--    调整作息时不要修改旧行：给旧行填上 valid_to，再插入新行。
--    这样历史上每一天当时的安排都能还原，完成率不会被新作息改掉。
-- ---------------------------------------------------------------------
CREATE TABLE schedule (
  id             INT UNSIGNED      NOT NULL AUTO_INCREMENT  COMMENT '作息项编号',
  day_type       ENUM('week','end') NOT NULL                COMMENT 'week 工作日（周一到周五），end 周末',
  start_time     TIME              NOT NULL                 COMMENT '开始时间',
  end_time       TIME                  NULL                 COMMENT '结束时间；只有时间点的项（如睡觉）为空',
  task_id        INT UNSIGNED      NOT NULL                 COMMENT '逻辑外键 → task.id',
  planned_min    SMALLINT UNSIGNED NOT NULL DEFAULT 0       COMMENT '计划时长（分钟）',
  count_in_rate  TINYINT(1)        NOT NULL DEFAULT 1       COMMENT '1 需要打卡（学习、复盘、规划），0 不需要打卡（休息、用餐、洗漱等非学习时间）',
  valid_from     DATE              NOT NULL                 COMMENT '生效日期',
  valid_to       DATE                  NULL                 COMMENT '失效日期（含当天），为空表示一直有效',
  PRIMARY KEY (id),
  UNIQUE KEY uk_schedule_slot (day_type, start_time, valid_from),
  KEY idx_schedule_task (task_id),
  CONSTRAINT ck_schedule_rate  CHECK (count_in_rate IN (0,1)),
  CONSTRAINT ck_schedule_range CHECK (valid_to IS NULL OR valid_to >= valid_from)
) ENGINE=InnoDB COMMENT='作息表';

-- ---------------------------------------------------------------------
-- 3. 打卡表
--    status:
--      done     完成。actual_min 为空时按计划时长计
--      partial  部分完成。必须填 actual_min
--      skipped  主动跳过。可在 note 里写原因
--      started  已打开始卡、还没打结束卡（过了结束打卡时间仍是这个状态，算未打卡）
--    没有记录 = 没打卡。时间段已过还没有记录的，页面上显示为红色“未完成”。
--    is_makeup = 1 表示事后补打卡；补打卡不记备注（note 必须为空）。
-- ---------------------------------------------------------------------
CREATE TABLE checkin (
  id            INT UNSIGNED  NOT NULL AUTO_INCREMENT          COMMENT '打卡编号',
  checkin_date  DATE          NOT NULL                         COMMENT '哪一天的事项',
  schedule_id   INT UNSIGNED  NOT NULL                         COMMENT '逻辑外键 → schedule.id',
  status        ENUM('done','partial','skipped','started') NOT NULL DEFAULT 'done' COMMENT 'done 完成 / partial 部分完成 / skipped 跳过 / started 已开始还没结束',
  started_at    DATETIME          NULL                         COMMENT '计时开始',
  ended_at      DATETIME          NULL                         COMMENT '计时结束',
  actual_min    SMALLINT UNSIGNED NULL                         COMMENT '实际用时（分钟），为空按计划时长计',
  is_makeup     TINYINT(1)    NOT NULL DEFAULT 0               COMMENT '1 补打卡',
  note          VARCHAR(500)      NULL                         COMMENT '备注：跳过原因、复盘内容等；补打卡不记备注',
  created_at    DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  updated_at    DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '最后修改时间',
  PRIMARY KEY (id),
  UNIQUE KEY uk_checkin_day_slot (checkin_date, schedule_id),
  KEY idx_checkin_schedule (schedule_id),
  CONSTRAINT ck_checkin_makeup  CHECK (is_makeup IN (0,1)),
  CONSTRAINT ck_checkin_partial CHECK (status <> 'partial' OR actual_min IS NOT NULL),
  CONSTRAINT ck_checkin_timer   CHECK (ended_at IS NULL OR started_at IS NULL OR ended_at >= started_at),
  CONSTRAINT ck_checkin_makeup_note CHECK (is_makeup = 0 OR note IS NULL)
) ENGINE=InnoDB COMMENT='打卡表';

-- ---------------------------------------------------------------------
-- 4. 视图：每天应该做的所有事项
--    从作息最早生效日起逐日展开到今天，最多展开 10000 天（约 27 年）；
--    周六、周日用周末作息。每一行带上打卡结果，没打卡的 status 为 NULL。
-- ---------------------------------------------------------------------
CREATE VIEW v_daily_plan AS
SELECT
  d.plan_date,
  s.day_type,
  s.id                AS schedule_id,
  s.start_time,
  s.end_time,
  t.id                AS task_id,
  t.name              AS task,
  t.category,
  s.planned_min,
  s.count_in_rate,
  c.id                AS checkin_id,
  c.status,
  c.is_makeup,
  CASE c.status
    WHEN 'done'    THEN COALESCE(c.actual_min, s.planned_min)
    WHEN 'partial' THEN c.actual_min
    ELSE 0
  END                 AS effective_min,
  c.note
FROM (
  SELECT DATE_ADD(b.first_day, INTERVAL n.n DAY) AS plan_date
  FROM (SELECT MIN(valid_from) AS first_day FROM schedule) b
  JOIN (
    SELECT a.i + 10*b.i + 100*c.i + 1000*d.i AS n
    FROM       (SELECT 0 i UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) a
    CROSS JOIN (SELECT 0 i UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) b
    CROSS JOIN (SELECT 0 i UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) c
    CROSS JOIN (SELECT 0 i UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d
  ) n ON DATE_ADD(b.first_day, INTERVAL n.n DAY) <= CURDATE()
) d
JOIN schedule s
  ON s.day_type = IF(DAYOFWEEK(d.plan_date) IN (1,7), 'end', 'week')
 AND s.valid_from <= d.plan_date
 AND (s.valid_to IS NULL OR d.plan_date <= s.valid_to)
JOIN task t ON t.id = s.task_id
LEFT JOIN checkin c ON c.checkin_date = d.plan_date AND c.schedule_id = s.id;

-- ---------------------------------------------------------------------
-- 5. 视图：每日指标
--    completion_rate 完成率     = 完成项 / 应打卡项（只算需要打卡的学习项；部分完成算半项）
--    study_rate      学习完成率 = 需要打卡项（学习、复盘、规划）的实际分钟 / 计划分钟
--    missed_items    未打卡     = 没有记录的项（今天还没到的时段也算在内，当天结束后才是最终值）
-- ---------------------------------------------------------------------
CREATE VIEW v_daily_stats AS
SELECT
  plan_date,
  day_type,
  SUM(count_in_rate)                                                 AS planned_items,
  SUM(count_in_rate * (status <=> 'done'))                           AS done_items,
  SUM(count_in_rate * (status <=> 'partial'))                        AS partial_items,
  SUM(count_in_rate * (status <=> 'skipped'))                        AS skipped_items,
  SUM(count_in_rate * (status IS NULL OR status <=> 'started'))      AS missed_items,
  SUM(count_in_rate * (is_makeup <=> 1))                             AS makeup_items,
  ROUND(100 * SUM(count_in_rate * ((status <=> 'done') + 0.5 * (status <=> 'partial')))
        / NULLIF(SUM(count_in_rate), 0), 1)                          AS completion_rate,
  SUM(IF(count_in_rate = 1, planned_min,   0))                      AS study_planned_min,
  SUM(IF(count_in_rate = 1, effective_min, 0))                      AS study_actual_min,
  ROUND(100 * SUM(IF(count_in_rate = 1, effective_min, 0))
        / NULLIF(SUM(IF(count_in_rate = 1, planned_min, 0)), 0), 1) AS study_rate
FROM v_daily_plan
GROUP BY plan_date, day_type;

-- ---------------------------------------------------------------------
-- 6. 视图：每周指标（周一为一周的第一天）
-- ---------------------------------------------------------------------
CREATE VIEW v_weekly_stats AS
SELECT
  DATE_SUB(plan_date, INTERVAL WEEKDAY(plan_date) DAY)               AS week_start,
  DATE_ADD(DATE_SUB(plan_date, INTERVAL WEEKDAY(plan_date) DAY), INTERVAL 6 DAY) AS week_end,
  COUNT(*)                                                           AS days,
  SUM(planned_items)                                                 AS planned_items,
  SUM(done_items)                                                    AS done_items,
  SUM(partial_items)                                                 AS partial_items,
  SUM(skipped_items)                                                 AS skipped_items,
  SUM(missed_items)                                                  AS missed_items,
  SUM(makeup_items)                                                  AS makeup_items,
  ROUND(100 * (SUM(done_items) + 0.5 * SUM(partial_items))
        / NULLIF(SUM(planned_items), 0), 1)                          AS completion_rate,
  ROUND(SUM(study_planned_min) / 60, 1)                              AS study_planned_hours,
  ROUND(SUM(study_actual_min)  / 60, 1)                              AS study_actual_hours,
  ROUND(100 * SUM(study_actual_min) / NULLIF(SUM(study_planned_min), 0), 1) AS study_rate,
  MAX(completion_rate)                                               AS best_day_rate,
  MIN(completion_rate)                                               AS worst_day_rate
FROM v_daily_stats
GROUP BY week_start, week_end;

-- =====================================================================
-- 初始数据
-- =====================================================================

-- 事项（25 项）
INSERT INTO task (name, category) VALUES
  ('起床',             'life'),
  ('洗漱',             'life'),
  ('整理一天计划',     'plan'),
  ('浅度科研（课题）', 'study'),
  ('浅度科研',         'study'),
  ('深度科研',         'study'),
  ('休息',             'rest'),
  ('午餐',             'meal'),
  ('上午复盘',         'plan'),
  ('午休',             'rest'),
  ('总结复盘',         'plan'),
  ('晚餐',             'meal'),
  ('娱乐',             'fun'),
  ('晚间规划',         'plan'),
  ('深度研究学习',     'study'),
  ('背诵面试原理',     'study'),
  ('洗衣、鞋',         'life'),
  ('本周总结、复盘',   'plan'),
  ('下午计划',         'plan'),
  ('深度写大论文',     'study'),
  ('短剧制作学习',     'study'),
  ('Agent 面试学习',   'study'),
  ('Agent 总结',       'plan'),
  ('做有意义的事情',   'fun'),
  ('睡觉',             'sleep');

-- 作息：生效日期 2026-11-12（工作日作息计划实行一个月，到期后给旧行填 valid_to 再插入新作息）
-- 学习、复盘、规划（类别 study、plan）需要打卡（count_in_rate = 1），其余为非学习时间，不需要打卡
INSERT INTO schedule (day_type, start_time, end_time, task_id, planned_min, count_in_rate, valid_from)
SELECT v.day_type, v.start_time, v.end_time, t.id, v.planned_min, IF(t.category IN ('study','plan'), 1, 0), '2026-11-12'
FROM (
  -- 周一至周五（28 项）
            SELECT 'week' AS day_type, '08:00' AS start_time, '08:10' AS end_time, '起床' AS name, 10 AS planned_min
  UNION ALL SELECT 'week','08:10','08:30','洗漱',20
  UNION ALL SELECT 'week','08:30','08:40','整理一天计划',10
  UNION ALL SELECT 'week','08:40','09:30','浅度科研（课题）',50
  UNION ALL SELECT 'week','09:30','09:40','休息',10
  UNION ALL SELECT 'week','09:40','10:40','深度科研',60
  UNION ALL SELECT 'week','10:40','10:50','休息',10
  UNION ALL SELECT 'week','10:50','11:50','深度科研',60
  UNION ALL SELECT 'week','11:50','12:30','午餐',40
  UNION ALL SELECT 'week','12:30','12:40','上午复盘',10
  UNION ALL SELECT 'week','12:40','13:35','午休',55
  UNION ALL SELECT 'week','13:35','13:45','洗漱',10
  UNION ALL SELECT 'week','13:50','14:30','浅度科研',40
  UNION ALL SELECT 'week','14:30','14:40','休息',10
  UNION ALL SELECT 'week','14:40','15:50','深度科研',70
  UNION ALL SELECT 'week','15:50','16:00','休息',10
  UNION ALL SELECT 'week','16:00','17:00','深度科研',60
  UNION ALL SELECT 'week','17:00','17:10','休息',10
  UNION ALL SELECT 'week','17:10','17:40','总结复盘',30
  UNION ALL SELECT 'week','17:40','19:00','晚餐',80
  UNION ALL SELECT 'week','19:00','19:20','娱乐',20
  UNION ALL SELECT 'week','19:20','19:30','晚间规划',10
  UNION ALL SELECT 'week','19:30','20:50','深度研究学习',80
  UNION ALL SELECT 'week','20:50','21:00','休息',10
  UNION ALL SELECT 'week','21:00','22:00','深度研究学习',60
  UNION ALL SELECT 'week','22:00','22:20','总结复盘',20
  UNION ALL SELECT 'week','22:20','22:45','洗漱',25
  UNION ALL SELECT 'week','22:45','23:20','背诵面试原理',35
  -- 周末（21 项）
  UNION ALL SELECT 'end','09:30','09:50','起床',20
  UNION ALL SELECT 'end','09:50','10:10','洗漱',20
  UNION ALL SELECT 'end','10:10','10:40','洗衣、鞋',30
  UNION ALL SELECT 'end','10:45','11:50','本周总结、复盘',65
  UNION ALL SELECT 'end','11:50','12:30','午餐',40
  UNION ALL SELECT 'end','12:40','13:50','午休',70
  UNION ALL SELECT 'end','14:00','14:20','下午计划',20
  UNION ALL SELECT 'end','14:20','15:30','深度写大论文',70
  UNION ALL SELECT 'end','15:30','15:40','休息',10
  UNION ALL SELECT 'end','15:40','16:50','深度写大论文',70
  UNION ALL SELECT 'end','16:50','17:00','休息',10
  UNION ALL SELECT 'end','17:00','18:10','短剧制作学习',70
  UNION ALL SELECT 'end','18:10','19:30','晚餐',80
  UNION ALL SELECT 'end','19:30','19:50','娱乐',20
  UNION ALL SELECT 'end','19:50','21:00','Agent 面试学习',70
  UNION ALL SELECT 'end','21:00','21:10','休息',10
  UNION ALL SELECT 'end','21:10','21:40','Agent 总结',30
  UNION ALL SELECT 'end','21:40','22:50','娱乐',70
  UNION ALL SELECT 'end','22:50','23:30','做有意义的事情',40
  UNION ALL SELECT 'end','23:30','23:50','洗漱',20
  UNION ALL SELECT 'end','23:50',NULL,'睡觉',0
) v
JOIN task t ON t.name = v.name;

-- =====================================================================
-- 常用操作示例（已注释，按需复制使用）
-- =====================================================================

-- 一键打卡：按计划时长计
-- INSERT INTO checkin (checkin_date, schedule_id) VALUES ('2026-11-12', 6);

-- 计时打卡：开始时写 started_at；结束时补 ended_at，并按实际分钟判断是否完成
-- INSERT INTO checkin (checkin_date, schedule_id, started_at) VALUES ('2026-11-12', 6, '2026-11-12 09:42:00');
-- UPDATE checkin c JOIN schedule s ON s.id = c.schedule_id
--    SET c.ended_at   = '2026-11-12 10:31:00',
--        c.actual_min = TIMESTAMPDIFF(MINUTE, c.started_at, '2026-11-12 10:31:00'),
--        c.status     = IF(TIMESTAMPDIFF(MINUTE, c.started_at, '2026-11-12 10:31:00') >= s.planned_min, 'done', 'partial')
--  WHERE c.checkin_date = '2026-11-12' AND c.schedule_id = 6;

-- 补打卡：做了但忘记点（补打卡不记备注）
-- INSERT INTO checkin (checkin_date, schedule_id, is_makeup) VALUES ('2026-11-12', 4, 1);

-- 跳过并写原因
-- INSERT INTO checkin (checkin_date, schedule_id, status, note) VALUES ('2026-11-12', 23, 'skipped', '临时开会');

-- 取消打卡
-- DELETE FROM checkin WHERE checkin_date = '2026-11-12' AND schedule_id = 6;

-- 查看某天每一项的状态
-- SELECT start_time, task, COALESCE(status, '未打卡') AS status
--   FROM v_daily_plan WHERE plan_date = '2026-11-12' ORDER BY start_time;

-- 每日、每周指标
-- SELECT * FROM v_daily_stats  ORDER BY plan_date  DESC LIMIT 7;
-- SELECT * FROM v_weekly_stats ORDER BY week_start DESC;

-- =====================================================================
-- 本脚本已包含的数据库变更（以后新增 migrations/xxx.sql 并把同样的修改写进本脚本时，在这里登记文件名）
-- =====================================================================
-- INSERT INTO schema_migrations (name) VALUES ('001_example.sql');
