# QCLP_Q — Quantum Constraint Logic Programming (QUBO / QAOA)

QCLP_Q lets you write ordinary constraint satisfaction and optimisation
problems in a Prolog-based language, and run the same problem file three
ways: a classical CLP(FD) solve, a Grover-style simulation, or a QAOA
quantum circuit.

Programming a quantum computer directly means choosing gates, angles
and qubit layouts, or hand-deriving QUBO coefficients. Most of that work
is quantum bookkeeping, not the problem you are trying to solve. In
QCLP_Q you write a `problem_spec/1` instead: domains, hard constraints
and soft costs. QCLP_Q compiles it to a QUBO and then to a QAOA circuit
in OpenQASM 3.0. One-hot encoding, penalty weights and cubic-to-quadratic
reduction are handled for you.

QCLP_G, the sibling package, compiles the same `.clp` files to Grover
search circuits built from logic gates instead. See
`docs/SHARED_COMPONENTS.md` for what the two packages share.

---

## 1. Prerequisites

SWI-Prolog 9.x (tested with 9.0.4 on Win11). Nothing else; everything ships as
Prolog source.

```bash
# Ubuntu/Debian
sudo apt-get install swi-prolog-nox
# macOS
brew install swi-prolog
```

## 2. Layout

```
QCLP_Q/
├── load.pl            entry point: load this file
├── README.md          this guide
├── CHANGELOG.md       what changed, and why
├── docs/
│   ├── Language_Reference.md   every constraint, the encoding, compiler options
│   └── SHARED_COMPONENTS.md    files shared with QCLP_G
├── clp_evaluator/     classical CLP(FD) solver        -> eval/1
├── grover_sim/        Grover amplitude simulator      -> gsim/1,2
├── qclp_qubo/         QUBO compiler, QAOA generator    -> qsim/1,2
├── sv_sim/            statevector simulator (runs the QASM)
├── Problems/          five worked problems + write-up
└── tests/             .clp problem files (plus generated .qbo / .qasm)
```

## 3. Load it

From the `QCLP_Q` directory:

```bash
swipl
```
```prolog
?- [load].
```
```
QCLP_Q loaded.  Type  info.  for more information.
```

You can also start with `swipl load.pl`. `info.` prints the command list
and options at any time.

## 4. Three ways to run a problem

| Command | What it does | Best for |
|---|---|---|
| `eval(File)` | Classical CLP(FD) solve: the exact optimum | Ground truth; checking your model |
| `gsim(File)`, `gsim(File, Opts)` | Grover search with an unknown number of solutions over the search space (exponential search: measure, check, retry with a growing K range). Hard constraints only: `fd_cost` is ignored. Limit 100,000 states. Options `top(N)`, `seed(S)`, `budget(B)` | Hard constraints with few solutions |
| `qsim(File)`, `qsim(File, Opts)` | `.clp` → QUBO → QAOA circuit → statevector simulation → sampled results | Optimisation; producing a quantum circuit |

`eval` and `gsim` take a `.clp` file. `qsim` takes a `.clp`, `.qbo` or
`.qasm` file and starts the pipeline at that stage.

```prolog
?- eval('tests/prob1_number_partition.clp').
```
```
--- [clpfd] Optimization Engine for [tests/prob1_number_partition.clp] ---
Optimal Assignment Found: [a1=0,a2=0,a3=0,a4=11,t12=0,t123=0,total=11]
Minimized Total Penalty: 0
```

```prolog
?- gsim('tests/prob1_number_partition.clp', [seed(1), top(3)]).
```
```
[gsim] Loading tests/prob1_number_partition.clp
[gsim] search space N=384; number of solutions unknown
[gsim] exponential search (unknown M), budget 177 oracle calls
[gsim]   round 1: K=0, measured |298>: checked, not a solution
...
[gsim]   round 11: K=2, measured |375>: checked, a solution
[gsim] found a solution after 11 oracle calls: [t123=11,t12=6,a4=0,a3=5,a2=5,a1=1]
...
Top 3 states by probability (out of 384):
  |375> : 6.2431%  [t123=11,t12=6,a4=0,a3=5,a2=5,a1=1]  ** solution **
  |8> : 6.2431%  [t123=0,t12=0,a4=11,a3=0,a2=0,a1=0]  ** solution **
  |383> : 0.2291%  [t123=11,t12=6,a4=11,a3=5,a2=5,a1=1]
```

`gsim` never solves the problem first, so it does not know how many
solutions there are. Each round runs K Grover iterations (K drawn from a
range that grows by 6/5 per failed round), measures one state and
checks it, as a quantum computer would have to. The probability list is
the simulator's view of the last round's state, not something hardware
could show.

```prolog
?- qsim('tests/tiny_neq.clp').
```
```
[1/3] Compiling tests/tiny_neq.clp
  4 qubits, 4 linear, 4 quadratic terms, constant=16
  wrote tests/tiny_neq.qbo
[2/3] Generating QAOA QASM from tests/tiny_neq.qbo
  wrote tests/tiny_neq.qasm
[3/3] Simulating tests/tiny_neq.qasm (4 qubits)
  Sampling 1000 shots...
  16 distinct outcomes
  (12.3%)  cost=8  [x=0,y=0]
  (10.8%)  cost=8  [x=1,y=1]
  (6.5%)  cost=0  [x=1,y=0]
  (6.5%)  cost=0  [x=0,y=1]
  (12 invalid/undecodable outcomes not shown)
```

Lower cost is better. `cost=0` rows are the valid solutions of `x ≠ y`;
"invalid" outcomes break the one-hot encoding. These numbers come from
the default QAOA angles (one layer, γ = 0.5, β = 0.3), which are not
tuned per problem, so the best answers are often not the most frequent
ones. Use `eval` to know the true optimum, and try other `p`, `gamma`
and `beta` values (§6).

**Rule of thumb:**

- Hard constraints, few solutions → `gsim`
- Pure optimisation (soft costs only) → `eval`, then `qsim`
- Mixed hard and soft → `eval` to verify, `qsim` for the circuit

## 5. Writing a problem

A `.clp` file holds one fact, `problem_spec/1`, listing domains and
constraints:

```prolog
problem_spec([
    fd_domain(x, 0, 1),          % x in {0,1}
    fd_domain(y, 0, 1),          % y in {0,1}
    fd_neq(x, y),                % hard: x ≠ y
    fd_cost(-1, fd_eq(x, 1))     % soft: reward x = 1
]).
```

- **Domains:** `fd_domain(V, Lo, Hi)`, or a value list
  `fd_domain(V, [1-3, 5-7, 10])` (`Lo-Hi` is a range, never subtraction).
- **Hard constraints:** `fd_eq`, `fd_neq`, `fd_lt`, `fd_le`, `fd_gt`,
  `fd_ge`, `fdalldifferent`, `fdsumeq(X,K,Y)` (X+K=Y), `fdsumneq`,
  `fd_product_eq`, `fd_weighted_sum`, `fd_abs_diff`, `fd_min`, `fd_max`,
  `fd_count`, `fd_atmost`, `fd_atleast`, `fd_xor`, `fd_implies`, `fd_or`.
- **Soft constraints:** `fd_cost(W, C)`. A negative `W` is a reward added
  when `C` holds; a positive `W` is a penalty added when `C` is violated.
- **Names** may be atoms (`v0`) or capitalised Prolog variables (`StartA`).

An unknown constraint, or a name with no `fd_domain`, is an error. It is
never silently ignored. The full vocabulary, with examples and the QUBO
encoding, is in `docs/Language_Reference.md`.

## 6. `qsim` options

```prolog
?- qsim('tests/factor21.clp',
        [shots(2000), top(5), p(3),
         gamma([0.2, 0.5, 0.8]), beta([0.8, 0.5, 0.2])]).
```

| Option | Default | Meaning |
|---|---|---|
| `shots(N)` | 1000 | samples drawn |
| `p(N)` | 1 | QAOA layers |
| `gamma([...])` | `[0.5]` | cost angles, one per layer |
| `beta([...])` | `[0.3]` | mixer angles, one per layer |
| `top(N)` | 5 | valid results shown |
| `amplitudes(true)` | off | print the full statevector instead of sampling |
| `outfile(Path)` | next to the `.qbo` | where to write the `.qasm` |

The QUBO compiler options (`hard_penalty(P)`, `onehot_penalty(P)`,
`aux_penalty(P)`) can be passed in the same list; see the language
reference.

Statevector simulation is limited to **12 qubits** (`sv_limit/1` in
`load.pl`). Above that, `qsim` still writes the QUBO and the QASM
circuit, but skips the simulation.

## 7. Other tools

- **Run a QASM file directly:** `?- qsim_run("tests/maxcut.qasm", [shots(500)]).`
  Or from the shell: `swipl sv_sim/sv_run.pl -- tests/maxcut.qasm --shots 500`.
- **Simulated annealing on the QUBO** (classical, no qubit limit):
  ```prolog
  ?- cd(qclp_qubo), [main3].
  ?- exec3('../tests/queens4.clp').
  ```
  ```
    16 binary variables, 16 linear terms, 120 quadratic terms, constant=768
    SA result: energy=0 (valid)
    assignment: [q0=1,q1=3,q2=0,q3=2]
  ```
  `exec3/2` takes `restarts(N)` and `iterations(N)`. Start a fresh
  Prolog session for this; `main3.pl` is not loaded by `load.pl`.

## 8. Problems to try

```prolog
?- qsim('tests/tiny_neq.clp').           % simplest: x ≠ y
?- gsim('tests/queens4.clp').            % 4-queens, hard constraints only
?- eval('tests/sudoku4.clp').            % 4×4 Sudoku, classical solve
?- gsim('tests/vertex_cover_triangle.clp', [top(3)]).
?- qsim('tests/prob2_maxcut.clp').       % Max-Cut, soft costs
```

`Problems/Five_Starter_Problems_QCLP.md` walks through five classic QUBO
problems (number partitioning, max-cut, vertex cover, cancer genomics,
order partitioning) with results.

## 9. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `qsim` reports "unknown extension" | Only `.clp`, `.qbo` and `.qasm` are accepted |
| `gsim requires a .clp file` | `gsim` works from the constraint spec only |
| `gsim` error: search space exceeds limit | More than 100,000 states. Use `eval` or `qsim`, or shrink the domains |
| `gsim` finds a solution after 0 oracle calls | Solutions are common, so a K = 0 round (a random guess) succeeded. With no hard constraints every state is a "solution" (`gsim` ignores `fd_cost`); use `eval` or `qsim` |
| `gsim`: "probably no solution" | Nothing found within the budget; raise `budget(B)` (default 9, times √N oracle calls) |
| "exceeds SV limit, skipping simulation" | More than 12 qubits. The QASM is still written |
| Best-cost answer is not the most frequent `qsim` outcome | Default QAOA angles are not tuned. Try more layers (`p(N)`) and other `gamma` / `beta` values |
| Error naming a constraint or a variable | The constraint is not in the vocabulary, or the variable has no `fd_domain` |

Do not load QCLP_G and QCLP_Q into the same Prolog session. Some of
their internal modules share names.

## 10. Cheat sheet

```prolog
?- [load].                                   % load everything
?- info.                                     % command list in-session
?- eval('file.clp').                         % classical CLP(FD) optimum
?- gsim('file.clp').                         % Grover search, unknown M
?- gsim('file.clp', [seed(1), top(3)]).
?- qsim('file.clp').                         % clp -> qubo -> qasm -> simulate
?- qsim('file.qbo').                         % start from a QUBO
?- qsim('file.qasm').                        % start from a circuit
?- qsim('file.clp', [shots(2000), p(2)]).
?- qsim_run("file.qasm", [shots(500)]).      % simulate any QASM 3 file
```
