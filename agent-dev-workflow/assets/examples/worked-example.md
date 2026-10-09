# worked-example.md — 走完 S1–S8 的最小例子（示例）

> ⚠️ **本文所有项目名、路径、行号、命令与输出都是虚构示例**，只用于演示"每个阶段该留下什么"的格式。
> 它们不对应任何真实文件，也不是任何真实测量结果。
>
> 格式权威来源：`SKILL.md` 与 `references/*.md`；空模板见 `assets/templates/`。

---

## 0. 场景（示例）

- **目标**：给虚构项目 `example-app` 的脚本 `src/example.py` 增加 `--dry-run` 参数。
- **背景**：`src/example.py` 是一个批量导入脚本，会把源目录的文件写进目标目录。用户希望在真正写入前先看一遍"将要发生什么"。
- **为什么用这个例子**：它足够小（一个源文件 + 一个测试文件），但踩得到边界（参数互斥、幂等、退出码、输出格式、回归），足以把 8 个阶段走一遍。

---

## S1 需求澄清与验收定义 → `.agent/add-dry-run/spec.md`

```markdown
# 给 example.py 增加 --dry-run

## 目标（一句话）
给 `src/example.py` 增加 `--dry-run`：打印将要执行的动作与目标路径，但**不修改任何文件**。

## 验收标准
- AC1 给定 `data/out` 中已有 3 个文件，执行
       `python src/example.py --dry-run --src data/in --dst data/out`
       期望：退出码 0；stdout 有 3 行以 `DRY-RUN` 开头的动作；`data/out` 文件数仍为 3。
- AC2 同一命令**连续执行两次**，两次 stdout 完全一致（幂等），`data/out` 始终不变。
- AC3 去掉 `--dry-run` 执行同一命令，行为与改动前一致（回归）：输出文件数与内容与基线一致。
- AC4 同时给 `--dry-run` 与 `--force`，期望退出码 2，stderr 含 `mutually exclusive`。
- AC5 目标路径含空格（示例：`data/my out`）时不崩溃，退出码 0。

## 范围外（这次不做）
- 不做交互式确认（`--interactive`）。
- 不重构 `src/example.py` 里既有的遍历循环。
- 不改 `data/` 下任何内容。

## 约束
- 目标平台/环境：Python 3.11，Windows + Linux 都要能跑。
- 性能/成本/时间预算：不改动 `plan_actions()` 的复杂度。
- 不能动的部分：现有 `--src/--dst/--force` 的参数语义与退出码。
- 交付形态：代码改动 + 测试 + 四层验证记录。

## 歧义与决定
| 问题 | 结论 | 依据 |
|---|---|---|
| `--dry-run` 输出格式？ | 一行一动作，统一 `DRY-RUN ` 前缀 | 用户答复（`ask_user_question` 选择题） |
| dry-run 时是否仍创建目标目录？ | **不创建**（零副作用） | 用户答复；与 AC1 的"文件数不变"一致 |

## 项目约定映射
- 本项目产物落盘在 `.agent/add-dry-run/`（`.gitignore` 已忽略 `.agent/`）。
```

**要点**：每条 AC 都是 `给定输入 → 执行命令 → 期望可观察结果`；AC4/AC5 是"判得了真假"的边界项，"更好用"这类词一个都没有。

---

## S2 现状勘查 → `.agent/add-dry-run/survey.md`

```markdown
# 现状勘查

## 现有实现
- 入口：`src/example.py:12` `main()` — 解析参数后分发
- 参数解析：`src/example.py:18` `parse_args()` — 目前只有 `--src/--dst/--force`
- 计划阶段：`src/example.py:34` `plan_actions()` — 返回"待执行动作列表"（纯计算，无副作用）
- 唯一落盘点：`src/example.py:41` `write_outputs()` — 全流程只有这里写磁盘

## 调用关系
- 上游（谁用它）：`src/cli.py:7`、`tests/test_example.py:20`
- 下游（它用谁）：`src/io_utils.py:15` `ensure_dir()`

## 既有测试与金标
- `tests/test_example.py`（6 条断言）→ 改动后必须仍全绿
- 无审计脚本

## 可复用的既有方案
- `src/example.py:34` 已有 `plan_actions()`，返回的就是"将要执行的动作" → `--dry-run` 直接复用它打印，**不另造第二套计划逻辑**

## 影响面
| 改动点 | 连带影响 | 回归范围 |
|---|---|---|
| `parse_args()` 增加两个分支 | `src/cli.py:7` 的传参路径 | `tests/test_example.py` 全量 |
| `write_outputs()` 增加短路 | 唯一落盘点 → 直接影响 AC1/AC3 | 需真实目录跑一次（L3） |

## 基线
- git rev `abc1234`（示例）；工作区干净

## 未知项
- `--force` 是否参与其他地方判断？→ 已查：仅 `src/example.py:44` 使用
```

**要点**：每条结论都带 `文件:行号`；"已有可复用的东西"写清楚，避免平行造第二套。

---

## S3 设计与决策 → `.agent/add-dry-run/design.md`

```markdown
# 设计

## 方案对比
| 方案 | 做法 | 代价 | 风险 | 可回退性 |
|---|---|---|---|---|
| A 最小改动 | `parse_args()` 加 `--dry-run`；`main()` 里在调用 `write_outputs()` 前判断，dry-run 时改为打印 `plan_actions()` 结果 | 低（约 15 行） | 低：不动既有写入逻辑 | 高（单点分支，删除即可） |
| B 结构性改 | 抽象出 `Executor`，dry-run 作为"空实现执行器"注入 | 高（新增抽象 + 改调用方） | 中：动到唯一落盘点 | 低 |

## 选定
**选 A**。理由：AC1–AC5 全部只要求"不写盘 + 打印计划"，而 `plan_actions()` 已经是无副作用的纯计算，方案 A 复用它就够。
不选 B：为一个参数引入执行器抽象属于范围膨胀，且会动到唯一落盘点，风险收益不成比例。

## 接口 / 数据变更
- 公开 API：`parse_args()` 新增 `--dry-run`（布尔，默认 False）；新增互斥校验（`--dry-run` 与 `--force` 互斥）
- 数据结构 / schema：无变化
- 配置格式：无变化
- 向后兼容：不带新参数时行为与改动前逐字节一致（AC3 守住）
- 迁移路径：不需要

## 失败模式
| 场景 | 期望行为 | 兜底 |
|---|---|---|
| 源目录为空 | 打印 0 个动作，退出码 0 | 不报错、不创建目标目录 |
| 目标路径含空格 | 正常执行 | 不使用字符串拼接路径 |
| 目标目录不存在且非 dry-run | 创建后写入（既有行为） | 复用 `ensure_dir()` |
| dry-run 且目标目录不存在 | **不创建** | 短路早于 `ensure_dir()` 调用 |
| `--force` 同时给出 | 退出码 2 + stderr 说明 | `argparse` 互斥组 |
| 进程被中途杀掉 | 无影响 | dry-run 无副作用；非 dry-run 沿用既有行为 |

## 明确不做
- 不做执行器抽象（方案 B）
- 不做 `--dry-run` 的输出格式化选项（`--format json`）
```

**要点**：至少两个方案、含最小改动方案；明确选一个并说清为什么不选另一个；失败模式覆盖空输入/边界/被杀。**S3 阶段不许改任何文件。**

---

## S4 任务切片 → `.agent/add-dry-run/tasks.md`

```markdown
# 任务切片

| ID | 目标 | 写入范围 | 验收方式 | 依赖 | owner |
|---|---|---|---|---|---|
| T1 | 参数互斥 + dry-run 短路，复用 `plan_actions()` | `src/example.py` | `pytest tests/test_example.py -q` 全绿 + 手跑 AC1 | — | 实现者 |
| T2 | 新增测试：AC1/AC2/AC4/AC5 + 幂等断言 | `tests/test_example.py` | `pytest tests/test_example.py -q`（断言数 ≥ 10） | T1（需要最终参数形态） | 实现者 |
| T3 | 独立验证并出 `verify.md` | `.agent/add-dry-run/verify.md` | 四层 L1–L4 逐条实跑 + 反向对照 | T1, T2 | **验证者（不参与实现）** |

## 并行约束
- T1 与 T2 的**写入范围不重叠**（`src/` vs `tests/`），但 T2 的断言必须绑定 T1 冻结的参数形态 → 用 `blocked_by` 串行，而不是并行瞎猜
- T3 与任何人都不能并行在同一产物上 → 独占 `.agent/add-dry-run/verify.md`

## 阻塞关系
- T2 blocked_by T1
- T3 blocked_by T1, T2
```

**要点**：每片有独立验收命令；写入范围互不重叠；依赖用显式阻塞表达，不靠"我等它"；S6 的 owner 从一开始就不是实现者。

---

## S5 实现 → `.agent/add-dry-run/evidence.md`

```markdown
# 实现证据

### 2026-10-09 14:20 — T1
$ python -m pytest tests/test_example.py -q
3 passed in 0.31s

$ python src/example.py --dry-run --src data/in --dst data/out
DRY-RUN copy a.txt -> data/out/a.txt
DRY-RUN copy b.txt -> data/out/b.txt
DRY-RUN copy c.txt -> data/out/c.txt
$ echo $LASTEXITCODE
0

备注：首次实现把 dry-run 短路放在了 ensure_dir() 之后 → AC1 发现空目标目录被创建，已把短路前移。

### 2026-10-09 14:55 — T2
$ python -m pytest tests/test_example.py -q
10 passed in 0.44s
```

**要点**：命令 + **原始输出**，不写"输出正常"；连踩到的坑也如实记录。

---

## S6 独立验证 → `.agent/add-dry-run/verify.md`

验证者只拿到 **S1 的 AC 原文 + 产物位置**，拿不到实现者的自我评价。

```markdown
# verify.md — add-dry-run

## 环境
- Python 3.11.9 / 基线 commit abc1234（示例）/ 2026-10-09 15:10

## L1 静态
$ python -m py_compile src/example.py tests/test_example.py
（无输出）
判定：✅ 通过（退出码 0）

## L2 单元
$ python -m pytest tests/test_example.py -q
10 passed in 0.44s
判定：✅ 通过（10 条断言，含 2 条幂等断言）

## L3 端到端
$ python src/example.py --dry-run --src data/in --dst "data/my out"
DRY-RUN copy a.txt -> data/my out/a.txt
...（共 3 行）
判定：✅ 通过；产物：`data/my out` **未被创建**（`Test-Path` 为 False）

## L4 验收
| 标准 | 判定 | 证据 |
|---|---|---|
| AC1 | ✅ | L3 输出：3 行 DRY-RUN，`data/out` 文件数仍为 3 |
| AC2 | ✅ | 连续两次运行 stdout diff 为空 |
| AC3 | ❌ | 无 dry-run 跑第二遍时 `data/out/b.txt` 内容被重复追加，与基线不一致 → **C 类** |
| AC4 | ✅ | `--dry-run --force` 退出码 2，stderr 含 mutually exclusive |
| AC5 | ✅ | L3 路径含空格的用例通过 |

## 反向对照
- 破坏：把 `src/example.py:41` 前的 dry-run 短路注释掉 → `test_dry_run_leaves_dst_untouched` 变红 ✅（证明该断言有效）
- 破坏：把互斥组去掉 → `test_dry_run_and_force_conflict` 变红 ✅

## 最可能挂的 3 个场景
1. 目标目录是符号链接 / 挂载点 → 未覆盖
2. 源目录含同名文件与子目录的混合结构 → 未覆盖
3. 并发跑两个实例（无锁）→ 未覆盖

## 失败分类
- AC3 属 **C 类（实现缺陷）**：应回 S5 修 `src/example.py:41` 附近，并**补一条回归断言**
```

**C 类回流**：回到 S5 修实现 + 加断言，然后**重跑 S6 的同一批命令**（不是只跑新测试）。第二次 L4 中 AC3 变为 ✅，判定 `verified`。

**要点**：三态判定（✅ / ❌ / ⚠️ 未验证）；必须有一次"故意改坏 → 断言变红"的反向对照；失败要分类而不是"再试一次"；`❌` 不等于结束，而是指定回哪一阶段。

---

## S7 审查与验收 → `.agent/add-dry-run/acceptance.md`

```markdown
# 验收

## 逐条判定
| 标准 | 判定 | 证据 | 备注 |
|---|---|---|---|
| AC1 | ✅ 通过 | verify.md §L4 + L3 原始输出 | |
| AC2 | ✅ 通过 | 两次运行 stdout diff 为空 | |
| AC3 | ✅ 通过 | 回 S5 修复后重跑，输出与基线一致 | 曾为 ❌，已加回归断言 |
| AC4 | ✅ 通过 | 退出码 2 + stderr 文案 | |
| AC5 | ⚠️ 未验证 | — | 仅 Windows 路径含空格可测；Linux 侧符号链接场景缺环境 |

## 结案检查
- [x] diff 只含预期改动（`src/example.py` + `tests/test_example.py`）
- [x] 无调试代码 / 临时文件 / 注释掉的代码
- [x] 无硬编码密钥、token、内网地址
- [ ] 未验证项已显式列出（见 AC5）→ **未验证项不得用"应该没问题"结案**

## 交付说明
### 做了什么
- `src/example.py` 增加 `--dry-run`（复用 `plan_actions()`，零副作用）与 `--dry-run/--force` 互斥校验
- `tests/test_example.py` 新增 4 组断言（含 2 条幂等断言）

### 怎么验证（你可以自己跑）
1. `python -m pytest tests/test_example.py -q` → 期望 `10 passed`
2. `python src/example.py --dry-run --src data/in --dst data/out` → 期望 3 行 `DRY-RUN`，且 `data/out` 不变
3. `python src/example.py --dry-run --force --src data/in --dst data/out` → 期望退出码 2

### 已知限制
- AC5 的 Linux 符号链接场景未验证（缺环境）

### 建议下一步
- 补一条 Linux CI 上的路径边界用例；并发场景是否需要加文件锁待确认
```

**要点**：裁决态显式（`verified` / `partial` / `failed`）；未验证项单独列出；交付说明四段式，用户能自己复现。

---

## S8 固化教训 → `.agent/add-dry-run/lessons.md`

```markdown
# 教训

## 2026-10-09 dry-run 短路位置放错，导致"只读"模式产生了副作用

- 现象：首次实现把 dry-run 短路放在 `ensure_dir()` 之后，只读模式仍然创建了目标目录；S6 的 AC1 才发现。
- 根因：实现时按"先准备环境再执行"的惯性写，没有把"零副作用"当成本次的硬性验收项来检查顺序。
- 规则：任何"只读 / 预演 / dry-run 模式"，其短路必须发生在**任何写操作之前**，并在 S1 里显式写成验收标准。
- 校验：`pytest tests/test_example.py -k "dry_run and untouched"`（已加入测试套件）
- 落盘位置：`DEVELOPMENT.md` §3.4（本项目约定文件）
```

**要点**：现象 → 根因 → 规则 → **可执行的校验** → 落盘位置。只写"下次注意"等于没写。

---

## 附：8 个阶段"最少要留下什么"

| 阶段 | 最少产物 | 出门门（不满足就别往下走） |
|---|---|---|
| S1 | `spec.md` | 每条 AC 都能判真假；范围外写明 |
| S2 | `survey.md` | 关键结论都带 `文件:行号` |
| S3 | `design.md` | ≥2 个方案 + 选定理由 + 失败模式 |
| S4 | `tasks.md` | 每片有独立验收 + 互斥写入范围 + 显式依赖 |
| S5 | 代码 + `evidence.md` | 命令与原始输出俱在，不造假 |
| S6 | `verify.md` | L1–L4 逐条实跑 + 反向对照 + 三态判定 |
| S7 | `acceptance.md` | 对照 S1 逐条裁决；未验证项显式列出 |
| S8 | `lessons.md` / 项目约定文件 | 人类否决已变成可重放校验 |

**这个例子里最容易被跳掉的三处**：① S2 的 `文件:行号`（跳过就开始靠猜）；② S6 的反向对照（跳过就得到一堆"永远是绿"的测试）；③ S8 的可执行校验（跳过就会再犯同一个错）。

> 小任务可以裁剪：S1–S4 压成几行内联说明、产物只留 `spec.md` + `verify.md`。
> **S6 独立验证与 S7 验收不可省。**
