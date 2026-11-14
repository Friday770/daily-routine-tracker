# Database migrations / 数据库变更

Put schema changes here as numbered SQL files, e.g. `001_add_column.sql`.
The backend runs every file it has not run before, in name order, each time it starts,
and records it in the `schema_migrations` table. End each statement with `;` and a newline.

When you add a migration, also apply the same change to `daily_routine.sql` and register the
file name at the bottom of it, so fresh installs do not run it again.

把数据库结构的修改按编号写成 .sql 放在这里（如 `001_add_column.sql`）。后端每次启动时按文件名顺序
执行还没执行过的文件，并记录到 `schema_migrations` 表。每条语句以分号加换行结尾。
新增变更时，也要把同样的修改写进 `daily_routine.sql`，并在文件末尾登记文件名，避免新装时重复执行。
