# QCLP_Q Language Reference

This is the full reference for the QCLP constraint language as compiled
by QCLP_Q's QUBO compiler (`qclp_qubo/qclp_qubo.pl`): every domain and
constraint form, the soft-cost rule, worked examples, compiler options,
and how the encoding works. For installing, loading and running
problems, start with the package `README.md`.

The same `problem_spec/1` file runs through every backend:

| Backend | Command | What it does |
|---|---|---|
| Classical (CLP(FD)) | `eval('file.clp')` | SWI-Prolog's CLP(FD) solver: the exact optimum, ground truth |
| Grover search | `gsim('file.clp')` | Grover search with an unknown number of solutions on an amplitude simulator (hard constraints only; never solves classically first) |
| QAOA | `qsim('file.clp')` | Compiles to a QUBO, generates a QAOA circuit in OpenQASM 3.0, simulates it |
| Simulated annealing | `exec3('file.clp')` (in `qclp_qubo/main3.pl`) | Compiles to a QUBO and anneals it classically |

The same files also run in QCLP_G (Grover circuits from logic gates),
which reads the same language except `fd_xor`.

---

## The QCLP Constraint Language

A problem is a `problem_spec/1` fact containing a list of declarations
and constraints. Identifiers may be Prolog atoms (`v0`, `w1`) or Prolog
variables (`Q0`, `X`) — both work identically.

---

## 1. Variable Declarations

### Contiguous domain

```prolog
fd_domain(Name, Lo, Hi)
```

`Name` ranges over integers `Lo, Lo+1, ..., Hi`. Encoded as a one-hot
block of `Hi-Lo+1` binary variables.

```prolog
fd_domain(colour, 1, 3)   % colour in {1,2,3}
fd_domain(Q0, 0, 3)        % queen column in {0,1,2,3}
```

### Sparse (enumerated) domain  *(Phase 3)*

```prolog
fd_domain(Name, [v1, v2, v3, ...])
```

`Name` can only take the listed values. Encoded as a one-hot block of
`length` bits — one per listed value. Values not in the list are
impossible; no "phantom" values are encoded.

```prolog
fd_domain(p2, [0, 5])          % contribution: either 0 or 5
fd_domain(x,  [0, 5, 10])      % three specific values only
fd_domain(s1, [0, 1, 5, 6])    % partial sums for {1}+{0,5}
```

**Why sparse domains matter**: `fd_domain(p2, 0, 5)` allows values
1,2,3,4 which may be physically meaningless and generate spurious QUBO
states. `fd_domain(p2, [0,5])` is exact.

### Clue (fixed value)

A hard `fd_eq(Var, Const)` where `Const` is a literal integer in `Var`'s
domain is treated as a **clue**: `Var` is fixed to that value and removed
from the one-hot encoding entirely (zero bits, no penalty terms).

```prolog
fd_domain(cell, 1, 4),
fd_eq(cell, 3)    % cell is fixed to 3, no bits allocated
```

---

## 2. Hard Constraints

Hard constraints must hold in every valid solution. Violation adds
`P_hard` to the QUBO energy per violated constraint. By default `P_hard`
is the larger of 8 and (total of all `|W|` in `fd_cost` terms) + 1, so no
ground state can trade a hard-constraint violation for a lower cost.

The same vocabulary is used by `eval`, `gsim` and the QUBO compiler. A
constraint outside it, or one the QUBO cannot encode exactly, is reported
as an **error** -- it is never skipped or approximated.

### Comparisons

| Constraint | Meaning |
|---|---|
| `fd_gt(X, Y)` | X > Y |
| `fd_ge(X, Y)` | X ≥ Y |
| `fd_xor(X, Y, Z)` | Z = X xor Y (bitwise; for 0/1 values, "exactly one of X, Y") |

### Equality and ordering

| Constraint | Meaning | Example |
|---|---|---|
| `fd_eq(X, Y)` | X = Y | `fd_eq(a, b)` |
| `fd_neq(X, Y)` | X ≠ Y | `fd_neq(v0, v1)` |
| `fd_lt(X, Y)` | X < Y | `fd_lt(start, end)` |
| `fd_le(X, Y)` | X ≤ Y | `fd_le(start, end)` |

`X` and `Y` may each be a domain variable, a literal integer, or a
clue-fixed variable.

### All-different

```prolog
fdalldifferent([X, Y, Z, ...])
fd_all_different([X, Y, Z, ...])   % synonym
```

All listed variables must take distinct values. Equivalent to `fd_neq`
for every pair, but compiled in one pass.

```prolog
fdalldifferent([Q0, Q1, Q2, Q3])   % queens in different columns
fdalldifferent([r0c0, r0c1, r0c2, r0c3])  % sudoku row
```

### Sum constraints

```prolog
fdsumeq(X, K, Y)       % X + K = Y
fdsumneq(X, K, Y)      % X + K ≠ Y
fd_sum_eq(X, K, Y)     % synonym for fdsumeq
fd_sum_neq(X, K, Y)    % synonym for fdsumneq
```

`X`, `K`, `Y` may each be a domain variable or a literal integer.

When all three are domain variables, the constraint is *cubic* in the
one-hot encoding. The compiler automatically reduces it to quadratic form via
Rosenberg substitution (Phase 2) — no user action needed.

```prolog
fdsumeq(StartA, 2, EndA)         % EndA = StartA + 2 (K constant)
fdsumeq(a0, b0, t0)              % t0 = a0+b0 (all vars, cubic→quadratic)
fdsumneq(Q0, 1, Q1)              % Q0+1 ≠ Q1 (diagonal constraint)
```

### Product constraint

```prolog
fd_product_eq(X, Y, Z)    % X * Y = Z
```

### Weighted sum  *(Phase 3)*

```prolog
fd_weighted_sum([W1*X1, W2*X2, ...], Target)
```

`W1*X1 + W2*X2 + ... = Target`. Coefficients are literal integers.
Any number of terms: with 3 or more, the QUBO compiler chains partial
sums through helper variables automatically (exact).

```prolog
fd_weighted_sum([3*x, 5*y], 21)    % 3x + 5y = 21
fd_weighted_sum([1*a], 0)          % a = 0
```

### Counting constraints  *(Phase 3)*

```prolog
fd_count(List, Val, N)      % exactly N variables in List equal Val
fd_atmost(N, List, Val)     % at most N equal Val
fd_atleast(N, List, Val)    % at least N equal Val
fd_min(List, M)             % M is the minimum of List
fd_max(List, M)             % M is the maximum of List
```

```prolog
fd_count([v0,v1,v2,v3], 1, 2)   % exactly 2 vertices in partition A
```

These are compiled exactly through helper variables (names starting
`_qclp_`): e.g. `fd_min([a,b,c], m)` becomes `t1 = min(a,b)`,
`t2 = min(t1,c)`, `m = t2`, and `fd_count` becomes one 0/1 indicator per
element plus a running sum. Each helper is a function of its inputs, so
its defining constraints can always be met; inside `fd_cost` only the
final comparison is soft.

### Absolute difference  *(Phase 3)*

```prolog
fd_abs_diff(X, Y, D)    % |X - Y| = D
```

### Implication and disjunction  *(Phase 3)*

```prolog
fd_implies(C1, C2)     % if C1 holds then C2 must hold
fd_or(C1, C2)          % at least one of C1, C2 must hold
```

`eval` and `gsim` accept any constraints as `C1` and `C2`. The QUBO
compiler multiplies the two violation indicators. It encodes the result
when the product has degree three or less in the qubits: for example
`fd_eq(x,1)` on 0/1 variables, or `fd_or(fd_eq(x,y), fd_eq(x,2))` on
0..2 domains (cubic terms are reduced to quadratic with auxiliary
qubits). Otherwise it reports an error, e.g. for
`fd_implies(fd_eq(x,y), fd_neq(y,z))` on 0..2 domains (degree four).

```prolog
fd_implies(fd_eq(x,1), fd_eq(y,0))   % x=1 → y=0
fd_or(fd_eq(a,0), fd_eq(b,0))        % at least one is zero
```

---

## 3. Soft Constraints (Costs and Rewards)

```prolog
fd_cost(W, Constraint)
```

`W` is an integer weight. The QUBO minimiser finds the **lowest**
energy state, so:

- **`W < 0` (reward)**: lowers energy when `Constraint` is **satisfied**.
  Use to *prefer* or *encourage* a state.
- **`W > 0` (penalty)**: raises energy when `Constraint` is **violated**.
  Use to *discourage* a state (without making it impossible).

### fd_cost in one rule

> **Negative weight** = reward for satisfaction.  
> **Positive weight** = penalty for violation.

| Goal | Write | Energy effect |
|---|---|---|
| Prefer X = V | `fd_cost(-W, fd_eq(X, V))` | -W when X=V |
| Discourage X = V | `fd_cost(+W, fd_neq(X, V))` | +W when X=V |
| Minimise count of "1"s | `fd_cost(-1, fd_eq(V, 0))` per V | -1 per excluded V |
| Maximise cut edges | `fd_cost(-1, fd_neq(u, v))` per edge | -1 per cut edge |

### Examples

```prolog
fd_cost(-5, fd_eq(w1, 2))   % reward: worker 1 on task 2 saves 5
fd_cost(8,  fd_neq(w3, 4))  % penalty: worker 3 on task 4 costs 8
fd_cost(-1, fd_neq(v0, v1)) % reward each cut edge in Max-Cut
fd_cost(-1, fd_eq(v, 0))    % reward vertex NOT in cover (minimise cover)
```

---

## 4. Worked Examples

### tests/tiny_neq.clp — Minimal example

```prolog
problem_spec([
    fd_domain(x, 0, 1),
    fd_domain(y, 0, 1),
    fd_neq(x, y)
]).
```

Two binary variables, one inequality. Both solutions (x=0,y=1) and
(x=1,y=0) give energy=0.

---

### tests/queens4.clp — Four Queens

Place 4 queens on a 4×4 board so none attack each other.
`fdalldifferent` enforces distinct columns; `fdsumneq` forbids diagonals.

```prolog
problem_spec([
    fd_domain(Q0,0,3), fd_domain(Q1,0,3),
    fd_domain(Q2,0,3), fd_domain(Q3,0,3),
    fdalldifferent([Q0,Q1,Q2,Q3]),
    fdsumneq(Q0,1,Q1), fdsumneq(Q1,1,Q0),
    fdsumneq(Q1,1,Q2), fdsumneq(Q2,1,Q1),
    fdsumneq(Q2,1,Q3), fdsumneq(Q3,1,Q2),
    fdsumneq(Q0,2,Q2), fdsumneq(Q2,2,Q0),
    fdsumneq(Q1,2,Q3), fdsumneq(Q3,2,Q1),
    fdsumneq(Q0,3,Q3), fdsumneq(Q3,3,Q0)
]).
```

Result: `[Q0=1,Q1=3,Q2=0,Q3=2]` (energy 0).

---

### tests/graphcolor4.clp — Graph Colouring

Colour 4 vertices (colours 1..3) so adjacent vertices differ.

```prolog
problem_spec([
    fd_domain(v0,1,3), fd_domain(v1,1,3),
    fd_domain(v2,1,3), fd_domain(v3,1,3),
    fd_neq(v0,v1), fd_neq(v1,v2), fd_neq(v2,v0),
    fd_neq(v2,v3)
]).
```

Result: a valid 3-colouring (energy 0).

---

### tests/assign4.clp — Worker Assignment with Preferences

```prolog
problem_spec([
    fd_domain(w1,1,4), fd_domain(w2,1,4),
    fd_domain(w3,1,4), fd_domain(w4,1,4),
    fdalldifferent([w1,w2,w3,w4]),
    fd_cost(-5, fd_eq(w1,2)),   % prefer w1 on task 2
    fd_cost(8,  fd_neq(w3,4))   % avoid w3 on task 4 (penalised when w3=4)
]).
```

Result: `[w1=2,...]`, energy=-5.

---

### tests/bestcost.clp — Interval Scheduling

Two jobs on one machine. Job A takes 2 time units, job B takes 1.
They cannot start simultaneously. A penalty applies if B ends at time 2.

```prolog
problem_spec([
    fd_domain(StartA,0,3), fd_domain(EndA,0,3),
    fd_domain(StartB,0,3), fd_domain(EndB,0,3),
    fdsumeq(StartA, 2, EndA),
    fdsumeq(StartB, 1, EndB),
    fd_neq(StartA, StartB),
    fd_cost(10, fd_neq(EndB, 2))    % penalised when EndB = 2
]).
```

Result: `[StartA=0,EndA=2,StartB=2,EndB=3]` (energy 0).

---

### tests/vertex_cover_triangle.clp — Minimum Vertex Cover

**From Mazumder & Tayur (2024). Shows how to convert a Python/dimod QUBO.**

Find the smallest set of vertices touching every edge of a triangle graph.

Python/dimod approach requires understanding QUBO coefficient formulas.
QCLP: just state that each edge must be covered, and reward exclusion.

```prolog
problem_spec([
    fd_domain(v1, 0, 1),
    fd_domain(v2, 0, 1),
    fd_domain(v3, 0, 1),

    fdsumneq(v1, v2, 0),   % edge (1,2): at least one endpoint in cover
    fdsumneq(v2, v3, 0),   % edge (2,3)
    fdsumneq(v1, v3, 0),   % edge (1,3)

    fd_cost(-1, fd_eq(v1, 0)),  % reward: v1 not in cover
    fd_cost(-1, fd_eq(v2, 0)),  % reward: v2 not in cover
    fd_cost(-1, fd_eq(v3, 0))   % reward: v3 not in cover
]).
```

Result: `[v1=0,v2=1,v3=1]`, energy=-1. Cover size 2 (optimal).

The `fd_cost` rule: reward exclusion (v=0) with negative weight.
The minimiser maximises exclusions = minimises cover size.

---

### tests/maxcut.clp — Maximum Cut

**From Mazumder & Tayur (2024).**

Partition vertices to maximise cut edges. Reward each cut edge.

```prolog
problem_spec([
    fd_domain(v0,0,1), fd_domain(v1,0,1), fd_domain(v2,0,1),
    fd_domain(v3,0,1), fd_domain(v4,0,1),

    fd_cost(-1, fd_neq(v0,v1)),   % reward edge (0,1) if cut
    fd_cost(-1, fd_neq(v0,v2)),   % reward edge (0,2) if cut
    fd_cost(-1, fd_neq(v1,v2)),   % reward edge (1,2) if cut
    fd_cost(-1, fd_neq(v1,v3)),   % reward edge (1,3) if cut
    fd_cost(-1, fd_neq(v2,v4)),   % reward edge (2,4) if cut
    fd_cost(-1, fd_neq(v3,v4))    % reward edge (3,4) if cut
]).
```

Result: 5 of 6 edges cut, energy=-5.

An edge is cut iff its endpoints are in different sets (`fd_neq`).
Negative `fd_cost` rewards cut edges. More cuts = lower energy = optimal.

---

### tests/number_partition.clp — Number Partitioning (equal weights)

**From Mazumder & Tayur (2024).**

Partition `{3,3,3,3}` into two equal-sum subsets.
Build a running count via `fdsumeq` chain and constrain it to 2.

```prolog
problem_spec([
    fd_domain(x1,0,1), fd_domain(x2,0,1),
    fd_domain(x3,0,1), fd_domain(x4,0,1),
    fd_domain(s12,  0,2),
    fd_domain(s123, 0,3),
    fd_domain(s1234,0,4),
    fdsumeq(x1,   x2,  s12),
    fdsumeq(s12,  x3,  s123),
    fdsumeq(s123, x4,  s1234),
    fd_eq(s1234, 2)
]).
```

Result: any 2-element subset, energy=0.

---

### tests/number_partition_weighted.clp — Number Partitioning (sparse domains)

**The Phase 3 showcase: weighted NP using sparse domains.**

Partition `{1,5,5,11}` (total=22) into two subsets each summing to 11.

Without sparse domains: `fd_domain(p2, 0, 5)` allows phantom values 1,2,3,4.
With sparse domains: `fd_domain(p2, [0,5])` is exact — only two values.

```prolog
problem_spec([
    fd_domain(p1, [0,1]),    % element 1: contributes 0 or 1
    fd_domain(p2, [0,5]),    % element 5: contributes 0 or 5
    fd_domain(p3, [0,5]),    % element 5: contributes 0 or 5
    fd_domain(p4, [0,11]),   % element 11: contributes 0 or 11

    fd_domain(s1, [0,1,5,6]),           % running sum after p1+p2
    fd_domain(s2, [0,1,5,6,10,11]),     % running sum after +p3
    fd_domain(s3, [0,11]),              % total sum (fixed to 11)

    fdsumeq(p1, p2, s1),
    fdsumeq(s1, p3, s2),
    fdsumeq(s2, p4, s3),

    fd_eq(s3, 11)    % perfect partition: sum of set A = 11
]).
```

Result: e.g. `[p4=11,rest=0]` or `[p1=1,p2=5,p3=5,p4=0]`, energy=0.

The intermediate sum domains `s1`, `s2` are also sparse — only values
reachable by the actual possible sums. This reduces bit count and
avoids spurious states.

---

### tests/cubic3.clp / tests/carry_chain.clp — Three-variable arithmetic (Phase 2)

When all three operands of `fdsumeq` are domain variables, cubic terms
arise and are **automatically** reduced to quadratic by Rosenberg
substitution. No user action needed.

```prolog
% tests/cubic3.clp: x+c=s with c=1 preferred
problem_spec([
    fd_domain(x,0,1), fd_domain(c,0,1), fd_domain(s,0,2),
    fdsumeq(x, c, s),          % all three vars -> Phase 2 auto-applied
    fd_cost(-1, fd_eq(c, 1))
]).
```

Result: `[x=0,c=1,s=1]`, energy=-1.

---

### tests/sparse_test.clp — Sparse domains basic test

```prolog
problem_spec([
    fd_domain(x, [0,5,10]),
    fd_domain(y, [0,5,10]),
    fd_domain(s, [0,5,10,15,20]),
    fdsumeq(x, y, s),
    fd_eq(s, 10),
    fd_cost(-1, fd_eq(x, 5))
]).
```

Result: `[x=5,y=5,s=10]`, energy=-1.
x and y each have exactly 3 one-hot bits; values 1,2,3,4,6,7,8,9 are
not in the encoding and cannot appear in any solution.

---

## 5. Three Canonical Problems Side by Side

From Mazumder & Tayur (2024), "Five Starter Problems":

| Problem | Python/dimod QUBO | QCLP constraint |
|---|---|---|
| **Number Partitioning** | `q_ii = s_i*(s_i-c)`, `q_ij = 2*s_i*s_j` | `fdsumeq` chain + `fd_eq(s,target)` |
| **Max-Cut** | `2*x_i*x_j - x_i - x_j` per edge | `fd_cost(-1, fd_neq(vi,vj))` per edge |
| **Min Vertex Cover** | `x_i + P*(1-x_i-x_j+x_i*x_j)` per edge | `fdsumneq(vi,vj,0)` + `fd_cost(-1,fd_eq(v,0))` |

In each case QCLP states the problem structure directly.
QUBO coefficients, penalty weights, and coupling strengths are
computed automatically.

---

## 6. Files

| File | Description |
|---|---|
| `qclp_qubo/qclp_qubo.pl` | QUBO compiler (module `qclp_qubo`): `compile_qubo/2,3`, `qubo_write/3` |
| `qclp_qubo/qubo_qaoa_qasm3.pl` | QAOA circuit generator, QUBO → OpenQASM 3.0 (`qaoa3/1,2`) |
| `qclp_qubo/qclp_qubo_sa.pl` | Simulated-annealing QUBO solver |
| `qclp_qubo/main3.pl` | Annealing driver: `exec3/1,2` (load on its own, from `qclp_qubo/`) |
| `qclp_qubo/loader.pl` | `solve_puzzle/1,2`: anneal a problem loaded as a Prolog module |
| `clp_evaluator/` | Classical CLP(FD) evaluator: `eval/1` |
| `grover_sim/` | Grover search with unknown M on an amplitude simulator: `gsim/1,2` |
| `sv_sim/` | Statevector simulator: `qsim_run/1,2` |
| `tests/*.clp` | Problem files used throughout this reference |
| `tests/*.qbo`, `tests/*.qasm` | Generated QUBOs and circuits (rewritten by `qsim`) |

---

## 7. Compiler Options

Pass these in the options list of `qsim/2`, `exec3/2` or `compile_qubo/3`.
The last two rows apply to simulated annealing (`exec3/2`) only:

| Option | Default | Effect |
|---|---|---|
| `hard_penalty(P)` | max(8, Σ\|W\| + 1) | Penalty per hard-constraint violation |
| `onehot_penalty(P)` | auto | One-hot penalty (auto = P_hard × (MaxDomain-1) × MaxDegree) |
| `aux_penalty(P)` | = onehot | Rosenberg substitution penalty (Phase 2) |
| `iterations(N)` | 6000 | SA steps per restart |
| `restarts(N)` | 10 | Number of SA restarts |

For large or difficult problems, increase restarts and iterations:

```prolog
?- exec3('../tests/number_partition_weighted.clp', [restarts(50), iterations(30000)]).
```

---

## 8. How the Encoding Works

### One-hot encoding

Each `fd_domain(V, Lo, Hi)` → `Hi-Lo+1` binary variables, exactly one = 1.
Each `fd_domain(V, [v1,...,vn])` → `n` binary variables, exactly one = 1.
A one-hot penalty enforces the "exactly one" constraint.

### Constraint → penalty terms

Each hard constraint becomes a **violation indicator**: a polynomial
over binary variables that is exactly 1 when the constraint is violated
(for valid one-hot assignments) and 0 when satisfied.
Multiplied by `P_hard` and added to the QUBO.

For binary-variable constraints the indicator is at most quadratic.

### Phase 2: cubic-to-quadratic (Rosenberg substitution)

Three-variable `fdsumeq`/`fdsumneq`/`fd_product_eq` produce cubic
monomials `b_I * b_J * b_K`. Each is reduced by introducing an
auxiliary binary variable `A = b_I AND b_J`, with penalty:

```
P_aux * (3A - 2*A*b_I - 2*A*b_J + b_I*b_J)
```

This is 0 iff `A = b_I AND b_J`. The cubic term becomes `A * b_K`.
The same `(b_I, b_J)` pair reuses the same aux variable throughout
the compile.

### Phase 3: sparse domains

`fd_domain(V, [v1,...,vn])` creates a one-hot block of exactly `n` bits,
one per listed value. Values between listed values are not encoded and
cannot appear in any solution.

Sparse domains enable:
- Weighted-sum chains: `fd_domain(p2, [0,5])` represents "contribution 0 or 5"
- Exact intermediate sum domains: `fd_domain(s1, [0,1,5,6])`
- Any two-value contribution variable: `fd_domain(x, [Lo, Hi])` for non-unit weights

---

## 9. Validation Results

All examples compile and solve to known-correct optima:

| File | Bits | Energy | Result |
|---|---:|---:|---|
| `tests/tiny_neq.clp` | 4 | 0 | x≠y satisfied |
| `tests/queens4.clp` | 16 | 0 | Valid 4-queens placement |
| `tests/graphcolor4.clp` | 12 | 0 | Valid 3-colouring |
| `tests/sudoku4.clp` | 52 | 0 | Valid completed 4×4 Sudoku (verified by classical evaluator) |
| `tests/assign4.clp` | 16 | -5 | w1=2 (reward), optimal assignment |
| `tests/bestcost.clp` | 16 | 0 | Optimal interval schedule |
| `tests/vertex_cover_triangle.clp` | 6 | -1 | Cover size 2 (optimal for triangle) |
| `tests/maxcut.clp` | 10 | -5 | 5 of 6 edges cut (optimal) |
| `tests/number_partition.clp` | 25 | 0 | Perfect partition of {3,3,3,3} |
| `tests/cubic3.clp` | 11 | -1 | x+c=s, c=1 preferred (Phase 2) |
| `tests/carry_chain.clp` | 22 | -2 | 2-column binary adder, both rewards (Phase 2) |
| `tests/sparse_test.clp` | 6 | -1 | Sparse domain x+y=10, x=5 preferred (Phase 3) |
| `tests/number_partition_weighted.clp` | 30 | 0 | Perfect partition of {1,5,5,11} (Phase 3, needs more SA effort) |

All results independently confirmed by the classical evaluator (`eval`).

---

## 10. The Connection to Quantum Physics

The "quantum terrain" view (Holehouse, "Quantum without Mystery"):

> *The terrain is the primary object; individual trajectories are not.*

In quantum computing: the `problem_spec/1` IS the terrain. The QUBO
penalty landscape IS the terrain made numerical. The measurement outcome
— which assignment the SA or quantum annealer finds — is the resolution
of that terrain into a single definite answer.

You never need to ask "which gate fired, which qubit flipped, which
annealing path was taken." The answer is determined entirely by the
constraint configuration. Writing the constraint program IS programming
the quantum computer.

---

## 11. Phase 3: Enhanced Constraint Language

### Sparse domain range syntax

Sparse domains now accept `Lo-Hi` range elements:

```prolog
fd_domain(v, [1-3, 5-7, 10])   % expands to {1,2,3,5,6,7,10}
fd_domain(p, [0-2, 5])          % expands to {0,1,2,5}
fd_domain(x, [0,5,10])          % plain list still works
```

This is the most natural way to express domains that skip certain
values (e.g. weighted contributions, allowed configuration states).

### New primitives

| Constraint | Meaning | Notes |
|---|---|---|
| `fd_weighted_sum([W1*X1,...], T)` | W1·X1 + W2·X2 + ... = T | N≥3 chained automatically |
| `fd_abs_diff(X, Y, D)` | \|X-Y\| = D | Cubic terms auto-reduced |
| `fd_min(List, M)` | M = min(List) | Exact, via helper chain |
| `fd_max(List, M)` | M = max(List) | Exact, via helper chain |
| `fd_count(List, Val, N)` | exactly N vars in List = Val | Val and N may be domain vars; exact |
| `fd_atmost(N, List, Val)` | at most N vars = Val | Exact |
| `fd_atleast(N, List, Val)` | at least N vars = Val | Exact |
| `fd_xor(X, Y, Z)` | Z = X xor Y | Exact |
| `fd_implies(C1, C2)` | C1 holds → C2 must hold | Exact when the product of the two indicators has degree ≤ 3; else an error |
| `fd_or(C1, C2)` | at least one of C1, C2 | Exact when the product of the two indicators has degree ≤ 3; else an error |

### Weighted Number Partitioning (Phase 3 showcase)

`tests/number_partition_weighted.clp`: partition `{1,5,5,11}` using sparse domains
for exact weighted contributions — impossible with contiguous domains.

```
SA result: energy=0  assignment: p1=1,p2=5,p3=5,p4=0 (A={1,5,5}, B={11})
```

### Test suite (tests/test1.clp through test7.clp)

| Test | Features exercised | Classical (`eval`) | QUBO + SA (`exec3`) |
|---|---|---|---|
| test1 | `fd_domain([1-3,5-7,10])` range syntax, `fd_eq` | 0 | 0 |
| test2 | range domains + `fdalldifferent` | 0 | 0 |
| test3 | `fd_weighted_sum` in `fd_cost` | 5 | 5 |
| test4 | `fd_abs_diff` hard + soft | 0 | 0 |
| test5 | `fd_min`, `fd_max` | -1 | -1 |
| test6 | `fd_count` with variable Val and N | 0 | 0 |
| test7 | All Phase 3 features combined | -2 | converges with high SA effort |

