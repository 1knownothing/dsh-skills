# agent-dev-workflow —— 通用 Agent 开发流程 skill

一句话：**先明确"什么算做完了"，再动手；写完的人不许自己验；没通过就分类重试，超限就升级给人。**

本目录是这套流程的**源目录**（开发侧），真正被 DSH 加载的只有 `agent-dev-workflow/` 子目录。
"为什么这样设计、证据强度如何"见 [EVALUATION.md](EVALUATION.md)；"走一遍完整流程长什么样"见 [worked-example.md](agent-dev-workflow/assets/examples/worked-example.md)。

---

## 1. 这是什么

一个 **DSH skill**（不是插件、不是脚本、不是服务）。它把「需求 → 实现 → 验收」固化成 8 个阶段（S1–S8）+ 门禁 + 独立验证，用来治这几类病：抢跑、幻觉接口、自证清白、假绿测试、打补丁、范围膨胀、记忆丢失、打转。

它**不自带任何调度器**：编排交给 DSH 现成原语（`subagent` / `spawn_teammate` / `workflow` / `team_task_*` / `create_goal`），skill 只负责约束纪律。

## 2. 装在哪

| 项 | 值 |
|---|---|
| 安装目标 | `<DSH_HOME>/skills/agent-dev-workflow/SKILL.md`，即文件系统 provider 的 **user-dsh 根（rank 400）** |
| 本机实际路径 | `C:\Users\17835\.dsh\skills\agent-dev-workflow\` |
| 生效范围 | **所有会话、所有项目**（与 `cwd` 无关） |
| 是否要改配置 | **不用**。不改 `cordis.yml` / `cordis.patch.yml` |
| 是否要重启 | **不用**。provider 有 watcher，目录会刷新 |
| preset 依赖 | `standard` / `ptc` / `cordis` 可见；**`minimal` preset 没挂 skill-filesystem，看不到** |

> `DSH_HOME` 未设置时，安装脚本回退到 `$HOME\.dsh`。

## 3. 安装 / 更新

在 `D:\1Anewproject\dev\dsh-skills` 目录下执行（Windows PowerShell 5.1 或 PowerShell 7+ 均可）。

### 开关它（最常用）

skill 一旦装上就是常驻的。要关掉它：

```powershell
# 关闭：从模型目录和人侧命令里同时消失（什么都不删）
powershell -ExecutionPolicy Bypass -File .\toggle.ps1 -Off

# 打开
powershell -ExecutionPolicy Bypass -File .\toggle.ps1 -On

# 看当前状态
powershell -ExecutionPolicy Bypass -File .\toggle.ps1 -Status
```

**原理**：开关不动源文件，而是改一个标记文件 `agent-dev-workflow\.disabled`，再把
`disable-model-invocation: true` + `user-invocable: false` **渲染进部署副本**。
所以源码在 git 里永远是"启用"状态，开关是本机状态。

想要更硬的关闭（连扫描根都不进），把 bundle 移进 provider 会跳过的 `.system` 目录：

```powershell
Move-Item "$env:DSH_HOME\skills\agent-dev-workflow" "$env:DSH_HOME\skills\.system\"
```

### 一条命令重装 + 校验

```powershell
# 渲染 + 安装 + 逐文件校验（退出码 0 = 部署与渲染结果字节一致）
powershell -ExecutionPolicy Bypass -File .\sync.ps1

# 只校验，不改动任何文件
powershell -ExecutionPolicy Bypass -File .\sync.ps1 -CheckOnly

# 证明开关不会漂移：反复 ON/OFF 三轮，断言源码字节不变
powershell -ExecutionPolicy Bypass -File .\cycle-test.ps1
```

**为什么必须校验**：DSH 里的 skill 是**副本**，改源文件不等于改部署。`sync.ps1` 会比对每个文件的 SHA256，并顺带检查 frontmatter 合法性、kebab-case、`description` 长度（面向模型的目录上限 500 字符）。退出码非 0 就说明两者不一致。

### 只装 / 卸载 / 预览

```powershell
# 安装（已安装则覆盖更新）
powershell -ExecutionPolicy Bypass -File .\agent-dev-workflow\scripts\install.ps1

# 先看会做什么，不真正写文件
powershell -ExecutionPolicy Bypass -File .\agent-dev-workflow\scripts\install.ps1 -WhatIf

# 装到非默认 DSH_HOME
powershell -ExecutionPolicy Bypass -File .\agent-dev-workflow\scripts\install.ps1 -DshHome 'D:\somewhere\.dsh'
```

脚本行为：

1. **护栏**：若"源目录 = 目标目录"（例如你运行的是**已安装副本**里的 `install.ps1`）立刻报错退出。
   不加这道护栏会先删目标、再复制一个已不存在的源，**把 skill 整个删光**。
2. **安装前校验** frontmatter——键名**大小写敏感**（`Name:` 会被拒绝，因为 DSH 的 YAML 解析取的是小写 `name`，取不到会静默跳过整个 skill）；`name` 必须存在、必须是**小写 kebab-case**（`^[a-z0-9]+(-[a-z0-9]+)*$`）、且与安装名（默认 `agent-dev-workflow`）一致；`description` 必须存在。不合法直接抛错，不会留下半个副本。
3. 若目标目录已存在则先删除，再整目录复制（**更新等于重装**，不会残留被删掉的文件）。
4. **安装后校验** `SKILL.md` 确实落盘，并列出复制过去的文件。

> ⚠️ 只运行 `install.ps1` 会**跳过哈希校验**。改完内容请用 `sync.ps1`。
> ⚠️ `install.ps1` / `sync.ps1` 刻意保持**纯 ASCII**（Windows PowerShell 5.1 会用 ANSI 代码页解码无 BOM 的 .ps1，中文会乱码并导致校验误报）。修改脚本时请沿用这个约定。
> ⚠️ PowerShell 的 `-match` / `-eq` **默认忽略大小写**。校验 frontmatter 键名时必须用 `-cnotmatch` / `-cne`，否则 `Name:`、`DESCRIPTION:` 会被放过。

## 4. 卸载

```powershell
powershell -ExecutionPolicy Bypass -File .\agent-dev-workflow\scripts\install.ps1 -Uninstall
```

目标目录不存在时会打印 `not installed (nothing to do).` 并正常退出（幂等）。

## 5. 文件结构

```text
dsh-skills/                              # 开发侧目录（不随安装复制）
├─ README.md                             # 本文件
├─ EVALUATION.md                         # 评估报告：为什么这样改 + 证据强度
├─ toggle.ps1                            # 开关：-Off / -On / -Status
├─ sync.ps1                              # 渲染 + 安装 + 逐文件哈希校验
├─ build-deploy.ps1                      # 把源 + 开关标记渲染成「部署副本」
├─ cycle-test.ps1                        # 证明开关不会漂移（28 项断言）
├─ deploy/                               # 渲染输出，自动生成（已 gitignore）
└─ agent-dev-workflow/                   # ← 这个目录才是 skill bundle（源，永远启用）
   ├─ SKILL.md                           # 入口：frontmatter + 全流程
   ├─ .disabled                          # 开关标记（存在=关闭，已 gitignore）
   ├─ references/                        # 按需加载的展开手册
   │  ├─ pipeline.md                     # 每阶段检查清单与产物格式
   │  ├─ verification.md                 # 独立验证方法论（四层 + 反向对照 + 失败分类）
   │  ├─ artifacts.md                    # 8 份产物的模板
   │  ├─ orchestration.md                # 在 DSH 里怎么编排（原语选型）
   │  └─ lessons-ledger.md               # 把人类否决变成可重放校验
   ├─ assets/
   │  ├─ templates/                      # spec.md / tasks.md / verify.md 骨架
   │  └─ examples/
   │     └─ worked-example.md            # 走完 S1–S8 的最小例子（示例数据）
   └─ scripts/
      └─ install.ps1                     # 安装 / 更新 / 卸载（含 frontmatter 校验与自毁护栏）
```

**只有 `SKILL.md` 会被自动发现**；其余文件在 skill 正文里按相对路径引用，需要时再读。
`minimal` preset 下 `references/`、`assets/`、`scripts/` 不会被当成独立 skill，也不会被递归发现。

## 6. 怎么验证生效

> 以下命令默认当前目录是 `D:\1Anewproject\dev\dsh-skills`（只有最后一条比对命令依赖这一点）。

### 6.1 验证文件已装好（可复制）

```powershell
# 定位安装根
$dsh  = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' }
$root = Join-Path $dsh 'skills\agent-dev-workflow'

# 1) SKILL.md 在不在  → 期望 True
Test-Path (Join-Path $root 'SKILL.md')

# 2) 装了哪些文件（对照上面的文件结构）
Get-ChildItem -Recurse -File $root |
    Select-Object @{ n = 'file'; e = { $_.FullName.Substring($root.Length + 1) } }, Length

# 3) frontmatter 头几行（name 应等于 agent-dev-workflow）
Get-Content (Join-Path $root 'SKILL.md') -TotalCount 5

# 4) 与源目录比对，确认装的是最新版  → 期望 True
(Get-FileHash (Join-Path $root 'SKILL.md')).Hash -eq
(Get-FileHash '.\agent-dev-workflow\SKILL.md').Hash
```

### 6.2 验证 DSH 真的能看见它

- **不用重启、不用改配置**：provider 的 watcher 会在会话的下一步刷新目录。
- 最直接的确认方式：在当前或新会话里让 Agent **复述它当前可用的 skill 清单**，看是否包含 `agent-dev-workflow`；或者直接下指令"用 agent-dev-workflow 帮我做一个 X"，看它是否按 S1–S8 推进。
- 看不到时按顺序排查：

| 现象 | 先查什么 |
|---|---|
| 完全看不到 | 当前会话的 agent preset 是不是 `minimal`（该 preset 没挂 skill-filesystem） |
| 装了但看不到 | `Test-Path` 那一步的 `$dsh` 是否指到你实际安装的位置（`DSH_HOME` 是否被改过） |
| 装了但看不到（其二） | frontmatter 的键名是不是**小写**（`Name:` / `DESCRIPTION:` 会被 DSH 静默跳过），以及 `name` 是不是合法 kebab-case。DSH 对不合法的 skill **只跳过 + warning**，模型目录里没有逐条诊断 |
| 校验脚本报错 | `SKILL.md` frontmatter 是否缺失，或 `name` 不合法 / 与安装名不一致 |
| 改了内容不生效 | 是不是只改了 `references/`（**改这些不触发刷新**）→ 跑 `sync.ps1` |
| 部署与源不一致 | 跑 `.\sync.ps1 -CheckOnly`，退出码非 0 就是不一致；`.\sync.ps1` 可修复 |
| 描述看起来不完整 | `description` 被截断到 500 字符（面向模型的目录只渲染前 500 个字符），属预期行为 |

## 7. 怎么用

- **自动触发**：正常提需求即可（"帮我实现 / 改 / 重构 / 修 / 加一个 X"），`description` 里的触发词会命中。
- **显式点名**：`用 agent-dev-workflow 做这件事`。
- **只评估不动手**：说"先别改，只评估"，此时只跑 S1–S3，不碰文件。
- **小任务裁剪**：改一个函数这类任务，S1–S4 可以压成几行内联说明；**S6 独立验证与 S7 验收不可省**。
- 产物默认落在项目的 `.agent/<task-slug>/`；项目已有文档约定时**服从项目既有约定**。

## 8. 边界与证据

- 这套流程**只有"独立验证者"一条是强实证**，其余是有限实证、机制支持或工程判断；**不要对外承诺"缺陷率下降"**。详见 [EVALUATION.md](EVALUATION.md) §三。
- 已知功能边界（preset、500 字符截断、刷新范围、不递归发现等）见 [EVALUATION.md](EVALUATION.md) §五。
- 本文件与 `EVALUATION.md` 位于 bundle **之外**，`install.ps1` 不会把它们复制进 DSH。
