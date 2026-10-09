# tasks.md — 任务切片

| ID | 目标 | 写入范围 | 验收方式 | 依赖 | owner |
|---|---|---|---|---|---|
| T1 |  | `src/a.py`, `tests/test_a.py` | `pytest tests/test_a.py -q` | — |  |
| T2 |  | `docs/30-x.md` | 含 X/Y/Z 三节 | T1 |  |

## 并行约束
- T1 与 T3 都写 `src/a.py` → **必须串行**
- 共享资源：端口 8080（T2 用）→ 排它

## 阻塞关系
- T2 blocked_by T1（需要 T1 最终接口）
