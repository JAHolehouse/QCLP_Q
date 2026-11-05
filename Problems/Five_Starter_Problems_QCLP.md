# Five Starter Problems in QCLP
## Based on Mazumder & Tayur (2024), Carnegie Mellon University

This document shows how each of the five QUBO problems from the paper
"Five Starter Problems for Quantum Computers" is expressed and solved
using the QCLP constraint language.

---

## Which Solver to Use

| Problem type | Best solver | Why |
|---|---|---|
| Hard constraints, few solutions | `gsim` | Grover search finds a solution without knowing how many there are |
| Pure optimisation (soft costs only) | `eval` then `qsim` | eval finds optimum; qsim samples the energy landscape |
| Mixed (hard + soft) | `eval` to verify, `qsim` for quantum | Hard constraints act as filters; soft costs as objective |

---

## Problem 1: Number Partitioning

**Instance:** S = {1, 5, 5, 11}. Find partition A | B minimising |sum(A) − sum(B)|.

**QCLP file:** `prob1_number_partition.clp`

**Key idea:** Represent each element's contribution as a domain variable with values
{0, si} — the element goes to B (contributes 0) or A (contributes si). Chain them
with `fdsumeq` and require the total to equal the half-sum.

```prolog
problem_spec([
    fd_domain(a1, [0, 1]),     % element 1 -> A or B
    fd_domain(a2, [0, 5]),     % element 5 -> A or B
    fd_domain(a3, [0, 5]),     % element 5 -> A or B
    fd_domain(a4, [0, 11]),    % element 11 -> A or B
    fd_domain(t12,  [0,1,5,6]),
    fd_domain(t123, [0,1,5,6,10,11]),
    fd_domain(total,[0,1,5,6,10,11,22]),
    fdsumeq(a1, a2, t12),
    fdsumeq(t12, a3, t123),
    fdsumeq(t123, a4, total),
    fd_eq(total, 11)
]).
```

**Results:**

| Solver | Result | Detail |
|---|---|---|
| `eval` | A={11}, B={1,5,5} | Penalty=0 ✓ |
| `gsim` | N=384, unknown M | A={1,5,5} found after 11 oracle calls (seed 1) |

```
?- eval('tests/prob1_number_partition.clp').
Optimal Assignment Found: [a1=0,a2=0,a3=0,a4=11,t12=0,t123=0,total=11]
Minimized Total Penalty: 0

?- gsim('tests/prob1_number_partition.clp', [seed(1), top(3)]).
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

The search measured A={1,5,5} in round 11. The final state gives both
valid partitions (A={1,5,5} and A={11}) equal probability, as expected:
they are the same partition with the groups swapped. That listing is the
simulator's view; hardware gives only the measured state.

---

## Problem 2: Max-Cut

**Instance:** 6-node graph with 8 edges: (0,3),(1,3),(1,4),(2,4),(2,5),(3,4),(3,5),(4,5).
Partition nodes into two sets to maximise cut edges.

**QCLP file:** `prob2_maxcut.clp`

**Key idea:** `fd_cost(-1, fd_neq(vi, vj))` rewards each cut edge with −1.
Minimising the total penalty maximises the number of cut edges.

```prolog
problem_spec([
    fd_domain(v0, 0, 1), ..., fd_domain(v5, 0, 1),
    fd_cost(-1, fd_neq(v0, v3)),
    fd_cost(-1, fd_neq(v1, v3)),
    ...
    fd_cost(-1, fd_neq(v4, v5))
]).
```

**Results:**

| Solver | Result | Detail |
|---|---|---|
| `eval` | {0,1,2,5} vs {3,4} | Penalty=−6 (6 edges cut) |

```
?- eval('tests/prob2_maxcut.clp').
Optimal Assignment Found: [v0=0,v1=0,v2=0,v3=1,v4=1,v5=0]
Minimized Total Penalty: -6
```

6 out of 8 edges cut — the maximum for this graph. With v3 = v4 = 1 the sets
are {0,1,2,5} and {3,4}; only edges (2,5) and (3,4) stay uncut. (The
"obvious" split {0,1,2} vs {3,4,5} cuts only 5: it leaves the triangle
(3,4), (3,5), (4,5) uncut.)

---

## Problem 3: Minimum Vertex Cover

**Instance:** 5-node graph with edges (0,2),(2,4),(1,4),(3,4). Find the smallest
set of vertices such that every edge has at least one endpoint in the set.

**QCLP file:** `prob3_vertex_cover.clp`

**Key idea:** Introduce complement variables ni = 1−xi. An edge (i,j) is uncovered
iff ni=1 AND nj=1, i.e. ni×nj=1. Hard constraint `fd_eq(uij, 0)` forbids uncovered
edges. Soft constraint `fd_cost(-1, fd_eq(xi, 0))` rewards each vertex left *out*
of the cover, so minimising the cost minimises the cover size. (A positive weight
penalises a constraint being *violated*, so `fd_cost(1, fd_eq(xi, 1))` would
penalise leaving a vertex out, and the optimum would be all five vertices.)

```prolog
problem_spec([
    fd_domain(x0,0,1), fd_domain(n0,0,1), fdsumeq(x0,n0,one0),
    fd_domain(one0,[1,1]), fd_eq(one0,1),
    ...
    fd_domain(u02,0,1), fd_product_eq(n0,n2,u02), fd_eq(u02,0),
    ...
    fd_cost(-1, fd_eq(x0, 0)), ...
]).
```

**Results:**

| Solver | Result | Detail |
|---|---|---|
| `eval` | Cover={x2,x4} | Penalty=−3 (3 vertices excluded: a size-2 cover) |
| `gsim` | N=1024, unknown M | A valid cover after 3 oracle calls (seed 1); `gsim` does not rank covers by size |

```
?- gsim('tests/prob3_vertex_cover.clp', [seed(1)]).
[gsim] search space N=1024; number of solutions unknown
[gsim] exponential search (unknown M), budget 288 oracle calls
...
[gsim]   round 6: K=1, measured |341>: checked, a solution
[gsim] found a solution after 3 oracle calls: [n4=0,x4=1,n3=0,x3=1,n2=0,x2=1,n1=0,x1=1,n0=0,x0=1]
```

`gsim` marks every assignment that satisfies the hard constraints, so it
returns *a* valid cover, here all five vertices, not a small one. It
ignores `fd_cost`. `eval` finds the minimum ({x2,x4}), and `qsim`
includes the costs in the QUBO.

---

## Problem 4: Cancer Genomics

**Instance:** 4 genes. Coverage D = {g0:3, g1:5, g2:4, g3:2} patients.
Exclusivity A = {g0-g1:2, g0-g2:1, g1-g2:3, g1-g3:1}. Maximise coverage
minus exclusivity (α=1.5).

**QCLP file:** `prob4_cancer_genomics.clp`

**Key idea:** `fd_cost(-alpha*Dii, fd_eq(gi,1))` rewards high-coverage genes.
`fd_cost(Aij, fd_eq(pij,0))` with `fd_product_eq(gi,gj,pij)` penalises co-selected
genes that share many patients: the penalty applies when pij = 0 is violated, i.e.
when both genes are selected.

```prolog
problem_spec([
    fd_domain(g0,0,1), ..., fd_domain(g3,0,1),
    fd_cost(-5, fd_eq(g0,1)),    % reward: -1.5 * 3
    fd_cost(-8, fd_eq(g1,1)),    % reward: -1.5 * 5
    fd_cost(-6, fd_eq(g2,1)),    % reward: -1.5 * 4
    fd_cost(-3, fd_eq(g3,1)),    % reward: -1.5 * 2
    fd_domain(p01,0,1), fd_product_eq(g0,g1,p01), fd_cost(2, fd_eq(p01,0)),
    ...
]).
```

**Results:**

| Solver | Result | Detail |
|---|---|---|
| `eval` | All 4 genes selected | Penalty=−15 (coverage 22 minus exclusivity 7) |

```
?- eval('tests/prob4_cancer_genomics.clp').
Optimal Assignment Found: [g0=1,g1=1,g2=1,g3=1,p01=1,p02=1,p12=1,p13=1]
Minimized Total Penalty: -15
```

All four genes selected: total coverage reward = 5+8+6+3 = 22, total exclusivity
penalty = 2+1+3+1 = 7, net = −15. This is the global optimum — the coverage
reward outweighs all exclusivity penalties.

> **Note:** For optimisation problems with no hard constraints, `gsim` treats all
> 2^4 = 16 assignments as valid, so its first measurement is already a "solution".
> Use `eval` or `qsim` for pure optimisation.

---

## Problem 5: Order Partitioning

**Instance:** 6 stocks A-F with values {300,100,100,200,200,100}, total=1000.
Risk factor 1 weights {3,1,1,2,2,1} (×0.1). Partition stocks so value is balanced
(each group = 500) and risk is balanced.

**QCLP file:** `prob5_order_partition.clp`

**Key idea:** Hard constraint `fd_eq(total, 500)` enforces value balance via a
`fdsumeq` chain of scaled stock contributions. Soft constraint on risk factor
balance via another `fdsumeq` chain.

```prolog
problem_spec([
    fd_domain(xA,0,1), ..., fd_domain(xF,0,1),
    % Scaled values: sA = xA*300, etc.
    fd_domain(sA,[0,300]), fd_product_eq(xA,wA,sA),
    ...
    % Value sum chain
    fdsumeq(sA,sB,t1), ..., fdsumeq(t4,sF,t5),
    fd_eq(t5, 500),       % hard: balanced value
    ...
    % Risk balance (soft)
    fd_cost(10, fd_neq(rt1e, 5))
]).
```

**Results:**

| Solver | Result | Detail |
|---|---|---|
| `eval` | {D,E,F} vs {A,B,C} | Penalty=0 (value and risk factor 1 both balanced) |

```
?- eval('tests/prob5_order_partition.clp').
Optimal Assignment Found: [xA=0,xB=0,xC=0,xD=1,xE=1,xF=1, ... ,rt1e=5]
Minimized Total Penalty: 0
```

Group A (xi = 1) is {D,E,F}: value 200+200+100 = 500 ✓, risk factor 1
2+2+1 = 5, exactly half of 10 ✓. Only risk factor 1 is modelled; the
paper's other two risk factors are left out of this file.

The soft cost is `fd_cost(10, fd_eq(rt1e, 5))`: a positive weight is
charged when its constraint is *violated*, so this costs 10 whenever risk
is **not** balanced. (Before 1 Oct 2026 the file had `fd_neq` here, which
charged 10 when risk *was* balanced, and the optimum reported penalty 10.)

---

## Summary

| Problem | Solver used | Search space | Solutions | Key result |
|---|---|---|---|---|
| Number Partition | `gsim` | 384 states | 2 | found after 11 oracle calls (seed 1) |
| Max-Cut | `eval` | 64 states | 1 optimum | 6/8 edges cut |
| Min Vertex Cover | `eval` / `gsim` | 1024 states | 14 covers | `eval`: minimum cover {x2,x4}; `gsim`: any valid cover |
| Cancer Genomics | `eval` | 16 states | 1 optimum | All 4 genes, net=−15 |
| Order Partition | `eval` | large | 1 optimum | {D,E,F} vs {A,B,C}, penalty 0 |

The QCLP system expresses all five problems in a uniform constraint language —
the same `.clp` file runs through classical CLP(FD), QAOA, or Grover simulation
without modification.
