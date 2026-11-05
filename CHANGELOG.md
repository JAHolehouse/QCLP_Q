# QCLP_Q Changelog

## 2 Oct 2026: `fd_or` and `fd_implies` in the QUBO compiler

Both failed to encode, even for the Language Reference's own example
`fd_implies(fd_eq(x,1), fd_eq(y,0))` on 0/1 variables:
`cannot encode fd_implies(...) in the QUBO (multiply(viol(...),viol(...)))`.
`multiply_viols/3` matched only the 4-field form of a violation term,
but `eq_viol` and similar build the 3-field form, so every product fell
through to "unsupported". One clause also stored an unevaluated sum as a
coefficient.

`multiply_viols/3` (`qclp_qubo/qclp_qubo.pl`) now normalises both
factors and multiplies them generally: a constant times anything; two
polynomials of degree at most 1; degree 1 times degree 2 (cubic terms,
Rosenberg-reduced as elsewhere). Higher degrees are still refused, with
the same error.

Checked by evaluating the QUBO energy of every bitstring and comparing,
for every assignment, "minimum energy = 0" with the constraints:

* `tests/or_implies.clp` (new): `fd_implies` and `fd_or` on 0/1
  variables, 6 qubits, all 8 assignments correct.
* `fd_or(fd_eq(x,y), fd_eq(x,2))`, x, y in 0..2: 8 qubits, all 9
  assignments correct (uses the cubic reduction).
* `fd_implies(fd_eq(x,y), fd_neq(y,z))` on 0..2 domains needs degree 4
  and is refused.

No shipped problem used either constraint before. Language Reference
§2 and the encoding table are corrected.

## 1 Oct 2026: `gsim` no longer solves the problem first

`gsim` used to enumerate the solutions classically, then use their
number M to choose Grover's iteration count, and mark them as the
oracle. A quantum computer cannot know M before searching.

* `gsim` now runs the exponential search of Boyer, Brassard, Høyer and
  Tapp: each round draws K uniformly from 0..⌈m⌉−1, runs K iterations,
  measures one state and checks it; m grows by 6/5 per failed round,
  up to √N. It gives up after `budget(B)`·√N oracle calls (default 9):
  "probably no solution". `seed(S)` makes a run repeatable.
* The oracle is the constraint check (`pcode_eval` → `holds/2`) on each
  state. No classical solution list is built.
* Output: the rounds, the solution found and the number of oracle
  calls, then the final state's probabilities, labelled as the
  simulator's view.
* The same change in QCLP_G covers `run/1`, `backend(exact)` and
  `export`; see its changelog.

## 1 Oct 2026: bug fixes, sync with QCLP_G, documentation

### Bugs fixed

| # | Where | Problem | Fix |
|---|---|---|---|
| 1 | `grover_sim/qsim_pp_grover.pl` | `gsim` on a search space smaller than `top(N)` failed (`tiny_neq`: 4 states, default `top(5)`): `length/append` cannot take 5 of 4 | Shows `min(N, states)` |
| 2 | `load.pl` | `info.` advertised `eval('file.clp')`, but `eval/1` was not exported, so the prompt asked to "correct" it to `eval_clp:eval(...)` | `eval/1` exported. Also `qsim_run/1,2`, which the docs use |
| 3 | `sv_sim/sv_run.pl` | `:- initialization(main, main)` fired whenever the simulator was loaded as a library: `swipl load.pl` printed the simulator's usage text and **exited**, and every scripted `swipl -g ... -t halt` run ended with it | The command-line entry point is registered only when `sv_run.pl` itself is the file launched |
| 4 | `load.pl` | `format_bitstring/3` raised an instantiation error on **every** call (a `yall` lambda used `Idx` without declaring it), so `qsim` crashed after sampling whenever no `.qbo` was found | Helper predicate instead of the lambda |
| 5 | `load.pl` | `qsim(File, [outfile(Path)])` re-guessed the `.qbo` from the `.qasm` name, so with any `outfile` it found none and hit bug 4 | The `.qbo` written in step 1 is passed through to the decoder |
| 6 | `tests/`, `Problems/` `prob5_order_partition.clp` | `fd_cost(10, fd_neq(rt1e, 5))` charged 10 when risk **was** balanced (the reversed-weight mistake fixed in four other files below). It went unnoticed because every value-balanced partition here is also risk-balanced, so the optimum always reported penalty 10 | `fd_cost(10, fd_eq(rt1e, 5))`: optimum now penalty 0. Header comment corrected (only risk factor 1 is modelled) |
| 7 | `prob2_maxcut.clp`, Five Starter Problems | Claimed {0,1,2} vs {3,4,5} is optimal; it cuts 5 edges. The optimum `eval` finds, {0,1,2,5} vs {3,4}, cuts 6 | Comment and write-up corrected |

### Changed behaviour

* **Grover iteration count** (`grover_sim/rp_grover.pl`), now the same
  rule as QCLP_G (superseded for `gsim` by the entry above; the formula
  remains for a known M). K maximises sin²((2K+1)θ) over K ≥ 1, smallest K on a
  tie. M/N ≤ 1/2 searches the first period; M/N > 1/2 searches
  K = 1..8. The previous fix (below) allowed K = 0. That is dropped,
  because QCLP_G needs an oracle in every exported circuit. For moderate
  M/N some K ≥ 1 matches or beats K = 0: M = 12, N = 16 gives K = 2,
  75% (the same); M = 13, N = 16 gives K = 3, 99.996% (against 81%);
  test2, M = 36, N = 42, gives K = 8, 90.9% (against 85.7%). When nearly
  every state is a solution, K = 0 is better (M = 319, N = 327: 97.6%
  against 79.4%), but such a problem does not need Grover.
* **`qsim` expands QASM macros in memory.** It no longer writes a
  `<name>_flat.qasm` file beside every circuit. The six stale
  `tests/*_flat.qasm` files are removed.
* **`sv_sim/sv_run.pl` and `sv_sim/qasm3_macro_pp.pl` replaced by
  QCLP_G's newer versions.** Additions: `qsim_run_string/1,2`,
  `qasm3_expand_and_run/1,2`, in-memory macro expansion inside
  `qsim_run/2`, and acceptance of unparenthesised gate headers and calls
  (the only form valid OpenQASM 3 allows without classical parameters).
  See `docs/SHARED_COMPONENTS.md`.
* `eval/1` is deterministic (no choice point left at the prompt).
* Load banner: `QCLP_Q loaded.  Type  info.  for more information.`
  (was "QCLP_Q Evaluator loaded").

### Documentation

* `QCLP_Q_Quickstart_Guide.md` → `README.md`, updated: `eval/1` in
  place of `eval_clp:eval/1`. Troubleshooting said `eval` where it meant
  `gsim`. New sections on `qsim_run` and simulated annealing.
* `qclp_qubo/README.md` → `docs/Language_Reference.md`. It still used
  the pre-QCLP names: "CUBO", "QPCL", `.txt` problem files, and
  `exec2`/`qaoa3` as the main commands. The file table listed
  `qpcl_qubo.pl`.
* `clp_evaluator/READEME.txt` removed. It described the retired
  `main2.pl` / `exec2/1` driver.
* `FIXES.md` → `CHANGELOG.md` (this file).
* New: `docs/SHARED_COMPONENTS.md`.
* Five Starter Problems: `gsim` on vertex cover was described as putting
  the size-2 covers on top. All 14 valid covers come out equal, because
  `gsim` ignores costs.

## Earlier: phase3_v4 corrections

Every change below was checked against an independent reference: a
separate SWI-Prolog CLP(FD) model of each test file. QUBO ground states
were computed exactly, by exhaustive enumeration, OR-Tools CP-SAT, or
min-sum variable elimination with ground-state counting (used for prob5,
whose 180-qubit QUBO has about 2.6 × 10¹² one-hot assignments). The three
methods agree wherever more than one applies.

### Result on the 29 files in `tests/`

| Tool | Before | After |
|---|---|---|
| `eval` (classical optimum) | 28 right; vaz wrong (`fd_xor` silently ignored) | **29 right** |
| QUBO compiler (exact ground states) | wrong on test5, test6, vaz; prob5 crashed (stack overflow) | **right on all 29** |
| `gsim` (Grover simulation) | 20 right; errors on bestcost, test3, test7; wrong on test5, test6, vaz | **right on all 26 within its 100,000-state limit**; sudoku4, sudoku9, prob5 exceed it and say so |

### 1. Cost examples that contradicted the `fd_cost` rule

QCLP's rule: a negative weight is a reward when the constraint holds, and a
positive weight is a penalty when it is **violated**. The evaluator,
compiler and README rule all implement this. Four examples were written
as if a weight were charged when the constraint holds. They now say what
they mean, using the README's own idioms:

| Example | Was | Now | Result (`eval`) |
|---|---|---|---|
| assign4 (`tests/`, README) | `fd_cost(8, fd_eq(w3,4))` | `fd_cost(8, fd_neq(w3,4))` | w3 off task 4, cost −5 |
| bestcost (`tests/`, README) | `fd_cost(10, fd_eq(EndB, 2))` | `fd_cost(10, fd_neq(EndB, 2))` | EndB = 3 (README result updated) |
| prob3_vertex_cover (`tests/`, `Problems/`) | `fd_cost(1, fd_eq(xi, 1))` | `fd_cost(-1, fd_eq(xi, 0))` | minimum cover {2, 4}, as stated (was all five vertices) |
| prob4_cancer_genomics (`tests/`, `Problems/`) | `fd_cost(A, fd_eq(pij, 1))` | `fd_cost(A, fd_eq(pij, 0))` | all four genes at −15 = −22 + 7, as the write-up explains (was −22) |

`Problems/Five_Starter_Problems_QCLP.md` is updated to match.

### 2. Evaluator (`clp_evaluator/clpfd_evaluator.pl`)

* One translator (`con_expr/3`) now defines every constraint for both
  hard use and `fd_cost`, so the two always agree.
* **Unrecognised constraints are errors.** They used to be silently
  ignored as hard constraints, and scored "never satisfied" inside
  `fd_cost`. In particular, `fd_implies`, `fd_or`, `fd_atmost` and
  `fd_atleast`, all documented in the README, had no effect at all.
* Added `fd_implies`, `fd_or`, `fd_atmost`, `fd_atleast`, `fd_gt`,
  `fd_ge` and `fd_xor` (bitwise: Z = X xor Y).
* An identifier with no `fd_domain` is an error naming it.

### 3. QUBO compiler (`qclp_qubo/qclp_qubo.pl`)

* **`fd_min` / `fd_max` were approximate.** They only enforced M ≤ every
  Xi (or ≥), never that M equals one of them, so test5 had 216 ground
  states instead of 30. They are now compiled exactly through helper
  variables: `t1 = min(X1,X2)`, `t2 = min(t1,X3)`, …, `M = tn`.
* **`fd_count` dropped constraints.** When both Val and N were variables,
  the degree-4 parts were silently skipped (test6: all of them), giving
  108 ground states instead of 27. Now there is one 0/1 indicator per
  element and a running sum, all exact.
* **`fd_atmost` / `fd_atleast`** were compiled as an *exact* count. They
  now use the same count and compare with ≤ / ≥.
* **`fd_weighted_sum` with 3+ terms** is now chained automatically, where
  before it was an error.
* **`fd_xor`, `fd_gt`, `fd_ge`** are encoded exactly; `fd_xor` was
  previously ignored.
* These rewritten constraints also work inside `fd_cost`. Their helper
  definitions are always hard, and each helper is a function of its
  inputs, so only the final comparison is soft.
* **Unencodable constraints are errors.** They used to be skipped with a
  WARNING line, or with nothing at all, and the ground state then
  answered a different problem.
* **Hard-penalty default** is now max(8, Σ|W| + 1), where W ranges over
  every `fd_cost` weight. With the old flat 8, a cost above 8 could make
  breaking a hard constraint the cheaper option.
* **Domain narrowing:** the result of a hard sum or product is narrowed
  to the values its inputs can actually produce. This is sound: no
  solution loses a value. prob5's partial sums were declared 0..1000
  (1001-bit one-hot blocks) and the compile ran out of stack. It now
  compiles to 180 qubits.
* **Size guard:** more than 4096 one-hot bits is a clear error, not a
  crash.
* Helper variables (named `_qclp_…`) are hidden from `qsim`'s decoded
  results.

### 4. `gsim` (`qclp.pl`, `grover_sim/`)

* **Capitalised names** (`StartA`, `M`, `N`) were read and then
  discarded, so they stayed unbound Prolog variables. The lookup then
  bound them to the first value it met: bestcost raised an error, and
  test5 and test6 gave wrong counts. They are now bound to their names.
* **One constraint vocabulary:** the two duplicate checkers (`check_one`
  in `rp_fd.pl`, `eval_constraint` in `rp_pcode.pl`) are replaced by one
  `holds/2`. That fixes `fd_weighted_sum` (its terms like `2*x` went to
  arithmetic unresolved: `type_error(evaluable, x/0)`) and adds
  `fd_xor`, `fd_implies`, `fd_or`, `fd_atmost` and `fd_atleast`.
  Unknown constraints and undeclared names are errors.
* **Iteration count** *(superseded 1 Oct 2026: K ≥ 1, see above)*: K is now chosen to maximise the success
  probability sin²((2K+1)θ), including K = 0. The old formula was clamped
  to K ≥ 1, which can overshoot when solutions are common: 12 solutions
  in 16 states gave K = 1 and a **0%** chance of a solution (K = 0 gives
  75%).
* **Diffusion:** states whose amplitude passed through zero were pruned
  and never reflected again. The inversion now covers all N states.
* **Speed:** the simulation is now dense and real-valued, and each state's
  oracle verdict is computed once, not once per iteration. test7
  (N = 46,464, K = 84) went from over 10 minutes to 18 seconds; its
  4 solutions get 24.9998% each, matching theory.

### Still open

* `fd_implies` / `fd_or` in the QUBO are limited to simple constraints
  (one one-hot bit each); anything else is now an error. `eval` and
  `gsim` accept any constraints.
* RProlog uses the other `fd_cost` reading (charged when the constraint
  holds). It needs a one-line change to match QCLP. *(Resolved 30 Sep 2026: QCLP_G, formerly RProlog,
  now uses QCLP's rule.)*
