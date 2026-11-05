% =============================================================================
% CLP(FD)-BASED EVALUATOR
% =============================================================================
% This module compiles a problem_spec/1 term (the same mini constraint
% language used by the original hand-rolled evaluator) directly into
% SWI-Prolog's clpfd library, and uses labeling/2 with min/1 to find
% the optimal assignment.
%
% Mapping from the mini-language to clpfd:
%
%   fd_domain(K, Lo, Hi)        -->  V in Lo..Hi
%   fd_eq(X, Y)                 -->  X #= Y
%   fd_neq(X, Y)                -->  X #\= Y
%   fd_lt(X, Y)                 -->  X #< Y
%   fd_le(X, Y)                 -->  X #=< Y
%   fdsumeq(X, A, Y)             }
%   fd_sum_eq(X, Y, Z)           }   X + A #= Y   (A may be a constant,
%   fdsumneq / fd_sum_neq        }   a variable, or an expression such
%                                 }   as 10*c1 - clpfd handles all of
%                                 }   these the same way)
%   fd_product_eq(X, Y, Z)      -->  X * Y #= Z
%   fdalldifferent(L)            }
%   fd_all_different(L)          }   all_different(L)
%
% Soft constraints, fd_cost(W, Constraint):
%   For each fd_cost(W, C), an indicator variable B in 0..1 is created
%   with B #<==> <reified C>. The total cost is then the linear sum,
%   over all fd_cost terms, of:
%       W * B          if W > 0   (penalty charged when C holds... )
%   Careful: in the *original* semantics, a positive weight W is a
%   PENALTY incurred when the constraint is VIOLATED, and a negative
%   weight W is a REWARD (i.e. cost decreases) when the constraint is
%   SATISFIED. So:
%       contribution = W * (1 - B)   if W > 0   (penalty when not C)
%       contribution = W * B         if W < 0   (reward when C holds)
%       contribution = 0             if W = 0
%   In both cases this can be written uniformly as a linear expression
%   in B, and clpfd's #= / linear-expression arithmetic handles it
%   directly.
%
% Identifiers used as "variables" in the source file (whether they are
% genuine Prolog variables like Q0, or atoms like v0/w1/s/e/n/d) are
% mapped to fresh clpfd variables via a simple association list built
% with assoc/2 (using ==-based lookup so that distinct Prolog
% variables used as distinct identifiers are never accidentally
% conflated).
% =============================================================================
:- module(clpfd_evaluator, [
    eval/3
]).

:- use_module(library(clpfd)).
:- use_module(library(assoc)).

% eval(+FilePath, -BestAssignment, -BestCost)
% BestAssignment is a list of Name=Value pairs in the order the
% corresponding fd_domain/3 declarations appear in the source file.
% Name is the source identifier: an atom (e.g. v0, w1, s) if the
% source used an atom, or the variable's source name (e.g. 'Q0') if
% the source used a genuine Prolog variable.
eval(FilePath, BestAssignment, BestCost) :-
    read_problem_spec(FilePath, Goals, VarNames),
    empty_assoc(Empty),
    declare_domains(Goals, Empty, VarMap, OrderedKeys),
    compile_constraints(Goals, VarMap, CostExpr0),
    CostVar #= CostExpr0,
    pairs_values_in_order(OrderedKeys, VarMap, Vars),
    labeling([ff, min(CostVar)], Vars),
    BestCost = CostVar,
    build_assignment(OrderedKeys, VarMap, VarNames, BestAssignment).

%% ---------------------------------------------------------------------------
%% Reading the problem_spec/1 term (preserving source variable names)
%% ---------------------------------------------------------------------------
read_problem_spec(FilePath, Goals, VarNames) :-
    setup_call_cleanup(
        open(FilePath, read, Stream),
        read_until_problem_spec(Stream, Goals, VarNames),
        close(Stream)
    ).

read_until_problem_spec(Stream, Goals, VarNames) :-
    read_term(Stream, Term, [variable_names(VNs)]),
    ( Term == end_of_file ->
        throw(error(existence_error(problem_spec_not_found, Stream), _))
    ; Term = problem_spec(Goals) ->
        VarNames = VNs
    ;   read_until_problem_spec(Stream, Goals, VarNames)
    ).

%% ---------------------------------------------------------------------------
%% Domain declarations: fd_domain(Key, Lo, Hi)  -->  fresh clpfd var
%% ---------------------------------------------------------------------------
% declare_domains(+Goals, +AssocIn, -AssocOut, -OrderedKeys)
% Walks Goals, and for every fd_domain(Key, Lo, Hi) creates a fresh
% clpfd variable V, posts "V in Lo..Hi", and records Key->V in the
% association. OrderedKeys is the list of Keys in declaration order
% (used later to build the displayed assignment and the labeling
% variable list in a stable order).
declare_domains([], Assoc, Assoc, []).
declare_domains([fd_domain(Key, Lo, Hi) | T], AssocIn, AssocOut, [Key | Keys]) :-
    integer(Lo), integer(Hi), !,
    V in Lo..Hi,
    put_assoc_key(Key, AssocIn, V, AssocMid),
    declare_domains(T, AssocMid, AssocOut, Keys).
declare_domains([fd_domain(Key, ValList) | T], AssocIn, AssocOut, [Key | Keys]) :-
    is_list(ValList), !,
    %% Sparse domain: V in the union of the given values/ranges.
    %% Each element is either a plain integer (a singleton value) or
    %% a Lo-Hi term denoting the inclusive range Lo..Hi (the source
    %% language's range syntax). clpfd itself uses Lo..Hi (not Lo-Hi)
    %% for ranges inside a domain expression, so every element is
    %% first normalised to clpfd's own syntax before the union
    %% V in D1 \/ D2 \/ ... is built.
    maplist(normalize_domain_elem, ValList, NormVals),
    build_domain_union(NormVals, DomExpr),
    V in DomExpr,
    put_assoc_key(Key, AssocIn, V, AssocMid),
    declare_domains(T, AssocMid, AssocOut, Keys).
declare_domains([_ | T], AssocIn, AssocOut, Keys) :-
    declare_domains(T, AssocIn, AssocOut, Keys).

% normalize_domain_elem(+Elem, -ClpfdDomTerm)
% Converts one element of a sparse fd_domain/2 value list into the
% domain syntax clpfd's in/2 expects: a plain integer stays a plain
% integer (singleton value), while a Lo-Hi term (the source
% language's inclusive-range syntax) becomes Lo..Hi.
normalize_domain_elem(Lo-Hi, Lo..Hi) :-
    integer(Lo), integer(Hi), !.
normalize_domain_elem(N, N) :-
    integer(N), !.

% build_domain_union(+NormalisedElems, -DomExpr)
% DomExpr is the \/-union of all the (already-normalised) elements.
build_domain_union([D], D) :- !.
build_domain_union([D|Ds], D\/Rest) :-
    build_domain_union(Ds, Rest).

% put_assoc_key(+Key, +AssocIn, +Value, -AssocOut)
% Atoms and genuine Prolog variables both work directly as assoc
% keys: assoc's underlying AVL tree uses standard order of terms
% (compare/3), which is stable for a fixed set of variables within a
% single execution - so two occurrences of the *same* source variable
% (e.g. both appearances of Q0) always compare as identical, while
% distinct variables (Q0 vs Q1) always compare as distinct, even
% though their internal reference numbers may print differently
% across calls. (Do NOT use term_to_atom/2 to build a key from a
% variable - it prints the variable's current internal reference,
% which is NOT stable across calls and causes the same variable to
% get different keys at different points, silently breaking the
% assoc.)
put_assoc_key(Key, AssocIn, Value, AssocOut) :-
    put_assoc(Key, AssocIn, Value, AssocOut).

get_assoc_key(Key, Assoc, Value) :-
    get_assoc(Key, Assoc, Value).

%% ---------------------------------------------------------------------------
%% Resolving a term (Key, constant, or arithmetic expression) to a
%% clpfd-arithmetic expression
%% ---------------------------------------------------------------------------
% resolve(+Term, +VarMap, -Expr)
% If Term is a key in VarMap, Expr is the corresponding clpfd
% variable. If Term is a number, Expr is that number. Otherwise (a
% compound arithmetic expression such as 10*c1), Expr is a structurally
% identical term with every leaf identifier resolved the same way -
% this lets fdsumeq(d, e, tu) and fdsumeq(y, 10*c1, tu) both work,
% since clpfd's #= accepts arbitrary arithmetic expressions.
resolve(Term, VarMap, Expr) :-
    ( number(Term) ->
        Expr = Term
    ; get_assoc_key(Term, VarMap, V) ->
        Expr = V
    ; compound(Term) ->
        Term =.. [F | Args],
        maplist(resolve_arg(VarMap), Args, RArgs),
        Expr =.. [F | RArgs]
    ;   % An identifier with no fd_domain declaration is an error
        % (previously it was left as-is and failed obscurely later).
        format(string(Msg), "~q is used in a constraint but has no fd_domain declaration", [Term]),
        throw(error(existence_error(fd_variable, Term), context(eval/3, Msg)))
    ).
resolve_arg(VarMap, Arg, Resolved) :- resolve(Arg, VarMap, Resolved).

%% ---------------------------------------------------------------------------
%% Compiling hard constraints and the soft-cost expression
%% ---------------------------------------------------------------------------
% compile_constraints(+Goals, +VarMap, -CostExpr)
% Posts all hard constraints found in Goals as clpfd constraints, and
% returns CostExpr, an arithmetic expression (in terms of fresh
% indicator variables) representing the total soft cost.
compile_constraints(Goals, VarMap, CostExpr) :-
    compile_goals(Goals, VarMap, CostTerms),
    sum_cost_terms(CostTerms, CostExpr).

compile_goals([], _, []).
compile_goals([fd_cost(W, Constraint) | T], VarMap, [Term | Rest]) :-
    !,
    reify_constraint(Constraint, VarMap, B),
    cost_term(W, B, Term),
    compile_goals(T, VarMap, Rest).
compile_goals([fd_domain(_,_,_) | T], VarMap, Rest) :-
    !,
    compile_goals(T, VarMap, Rest).
compile_goals([fd_domain(_,_) | T], VarMap, Rest) :-
    !,
    compile_goals(T, VarMap, Rest).
compile_goals([Goal | T], VarMap, Rest) :-
    post_hard_constraint(Goal, VarMap),
    compile_goals(T, VarMap, Rest).

% cost_term(+W, +IndicatorVar, -Term)
% Term is an arithmetic expression contributing to the total cost:
%   W > 0 (penalty when constraint is violated): W * (1 - B)
%   W < 0 (reward when constraint is satisfied): W * B
%   W = 0: contributes nothing
cost_term(W, B, Term) :-
    ( W > 0 -> Term = W*(1-B)
    ; W < 0 -> Term = W*B
    ; Term = 0
    ).

sum_cost_terms([], 0).
sum_cost_terms([T], T) :- !.
sum_cost_terms([T|Ts], T+Rest) :- sum_cost_terms(Ts, Rest).

% sum_expr(+ResolvedTerms, -Expr)
% Expr is the arithmetic sum of ResolvedTerms (e.g. used to build
% "2*X + 3*Y" out of [2*X, 3*Y] for fd_weighted_sum/2).
sum_expr([], 0).
sum_expr([T], T) :- !.
sum_expr([T|Ts], T+Rest) :- sum_expr(Ts, Rest).

% min_expr(+ResolvedList, -Expr) / max_expr(+ResolvedList, -Expr)
% Expr is a nested min(...)/max(...) clpfd arithmetic expression
% covering every element of ResolvedList (clpfd's min/2 and max/2
% are binary, so an n-ary min/max is built by right-folding).
min_expr([X], X) :- !.
min_expr([X|Xs], min(X, Rest)) :- min_expr(Xs, Rest).

max_expr([X], X) :- !.
max_expr([X|Xs], max(X, Rest)) :- max_expr(Xs, Rest).

% count_indicators(+ResolvedList, +ResolvedValue, -Indicators)
% Indicators is a list of fresh 0/1 clpfd variables, one per element
% of ResolvedList, with Indicator #<==> (Element #= ResolvedValue).
% Summing Indicators gives the number of list elements equal to
% ResolvedValue (used by fd_count/3).
count_indicators([], _, []).
count_indicators([X|Xs], Value, [B|Bs]) :-
    B #<==> (X #= Value),
    count_indicators(Xs, Value, Bs).

% post_hard_constraint(+Goal, +VarMap)
% Posts Goal as a hard clpfd constraint. all_different is posted with
% clpfd's own all_different/1 (stronger propagation); everything else
% goes through con_expr/3, the single translator shared with
% reify_constraint/3, so hard and soft constraints always mean the
% same thing. An unrecognised goal is an ERROR (it used to be silently
% ignored, so e.g. fd_implies, fd_or, fd_atmost and fd_atleast -- all
% documented in the README -- simply had no effect).
post_hard_constraint(fdalldifferent(L), VarMap) :-
    !, maplist(resolve_arg(VarMap), L, RL), all_different(RL).
post_hard_constraint(fd_all_different(L), VarMap) :-
    !, maplist(resolve_arg(VarMap), L, RL), all_different(RL).
post_hard_constraint(Goal, VarMap) :-
    con_expr(Goal, VarMap, Expr),
    call(Expr).

%% ---------------------------------------------------------------------------
%% Reifying a constraint to a 0/1 indicator variable
%% ---------------------------------------------------------------------------
% reify_constraint(+Constraint, +VarMap, -B)
% B is a fresh clpfd variable in 0..1 such that B #<==> "Constraint
% holds". Used to turn fd_cost(W, Constraint) into a linear cost
% contribution. An unsupported constraint inside fd_cost is an ERROR
% (it used to be scored as "never satisfied").
reify_constraint(Constraint, VarMap, B) :-
    con_expr(Constraint, VarMap, Expr),
    B #<==> Expr.

% con_expr(+Constraint, +VarMap, -Expr)
% Expr is a reifiable clpfd constraint expression equivalent to
% Constraint. This is the language's constraint vocabulary.
con_expr(fd_eq(X, Y), VM, RX #= RY)   :- !, resolve(X, VM, RX), resolve(Y, VM, RY).
con_expr(fd_neq(X, Y), VM, RX #\= RY) :- !, resolve(X, VM, RX), resolve(Y, VM, RY).
con_expr(fd_lt(X, Y), VM, RX #< RY)   :- !, resolve(X, VM, RX), resolve(Y, VM, RY).
con_expr(fd_le(X, Y), VM, RX #=< RY)  :- !, resolve(X, VM, RX), resolve(Y, VM, RY).
con_expr(fd_gt(X, Y), VM, RX #> RY)   :- !, resolve(X, VM, RX), resolve(Y, VM, RY).
con_expr(fd_ge(X, Y), VM, RX #>= RY)  :- !, resolve(X, VM, RX), resolve(Y, VM, RY).
con_expr(fdsumeq(X, A, Y), VM, E)     :- !, con_expr(fd_sum_eq(X, A, Y), VM, E).
con_expr(fd_sum_eq(X, Y, Z), VM, RX + RY #= RZ) :- !,
    resolve(X, VM, RX), resolve(Y, VM, RY), resolve(Z, VM, RZ).
con_expr(fdsumneq(X, A, Y), VM, E)    :- !, con_expr(fd_sum_neq(X, A, Y), VM, E).
con_expr(fd_sum_neq(X, Y, Z), VM, RX + RY #\= RZ) :- !,
    resolve(X, VM, RX), resolve(Y, VM, RY), resolve(Z, VM, RZ).
con_expr(fd_product_eq(X, Y, Z), VM, RX * RY #= RZ) :- !,
    resolve(X, VM, RX), resolve(Y, VM, RY), resolve(Z, VM, RZ).
con_expr(fdalldifferent(L), VM, E)    :- !,
    maplist(resolve_arg(VM), L, RL), pairwise_neq_expr(RL, E).
con_expr(fd_all_different(L), VM, E)  :- !, con_expr(fdalldifferent(L), VM, E).
con_expr(fd_weighted_sum(Terms, Total), VM, SumExpr #= RTotal) :- !,
    maplist(resolve_arg(VM), Terms, RTerms), resolve(Total, VM, RTotal),
    sum_expr(RTerms, SumExpr).
con_expr(fd_abs_diff(X, Y, D), VM, RD #= abs(RX - RY)) :- !,
    resolve(X, VM, RX), resolve(Y, VM, RY), resolve(D, VM, RD).
con_expr(fd_min(List, M), VM, RM #= MinExpr) :- !,
    maplist(resolve_arg(VM), List, RList), resolve(M, VM, RM), min_expr(RList, MinExpr).
con_expr(fd_max(List, M), VM, RM #= MaxExpr) :- !,
    maplist(resolve_arg(VM), List, RList), resolve(M, VM, RM), max_expr(RList, MaxExpr).
con_expr(fd_count(List, Value, N), VM, CountExpr #= RN) :- !,
    count_expr(List, Value, VM, CountExpr), resolve(N, VM, RN).
con_expr(fd_atmost(N, List, Value), VM, CountExpr #=< RN) :- !,
    count_expr(List, Value, VM, CountExpr), resolve(N, VM, RN).
con_expr(fd_atleast(N, List, Value), VM, CountExpr #>= RN) :- !,
    count_expr(List, Value, VM, CountExpr), resolve(N, VM, RN).
con_expr(fd_xor(X, Y, Z), VM, RZ #= RX xor RY) :- !,         % bitwise xor
    resolve(X, VM, RX), resolve(Y, VM, RY), resolve(Z, VM, RZ).
con_expr(fd_implies(C1, C2), VM, E1 #==> E2) :- !,
    con_expr(C1, VM, E1), con_expr(C2, VM, E2).
con_expr(fd_or(C1, C2), VM, E1 #\/ E2) :- !,
    con_expr(C1, VM, E1), con_expr(C2, VM, E2).
con_expr(Goal, _, _) :-
    format(string(Msg), "~q is not a recognised constraint (see docs/Language_Reference.md)", [Goal]),
    throw(error(domain_error(qclp_constraint, Goal), context(eval/3, Msg))).

% count_expr(+List, +Value, +VarMap, -CountExpr): number of List
% elements equal to Value, as a sum of fresh 0/1 indicators.
count_expr(List, Value, VM, CountExpr) :-
    maplist(resolve_arg(VM), List, RList), resolve(Value, VM, RValue),
    count_indicators(RList, RValue, Bs),
    sum_expr(Bs, CountExpr).

% pairwise_neq_expr(+Vars, -Expr): conjunction of X #\= Y over all pairs
pairwise_neq_expr(Vars, Expr) :-
    findall(I-J, (nth1(I, Vars, _), nth1(J, Vars, _), I < J), Pairs),
    (   Pairs == [] -> Expr = (0 #= 0)
    ;   maplist(pair_neq(Vars), Pairs, Es), conj_expr(Es, Expr)
    ).
pair_neq(Vars, I-J, X #\= Y) :- nth1(I, Vars, X), nth1(J, Vars, Y).
conj_expr([E], E) :- !.
conj_expr([E|Es], E #/\ R) :- conj_expr(Es, R).

%% ---------------------------------------------------------------------------
%% Building the final displayed assignment
%% ---------------------------------------------------------------------------
% pairs_values_in_order(+Keys, +VarMap, -Vars)
% Vars is the list of clpfd variables corresponding to Keys, in the
% given order (used as the labeling/2 variable list).
pairs_values_in_order([], _, []).
pairs_values_in_order([Key|Keys], VarMap, [V|Vs]) :-
    get_assoc_key(Key, VarMap, V),
    pairs_values_in_order(Keys, VarMap, Vs).

% build_assignment(+OrderedKeys, +VarMap, +VarNames, -Assignment)
% Assignment is a list of Display=Value pairs, where Display is
% either the source atom (e.g. v0, w1, s) or the source variable name
% (e.g. 'Q0') recovered via VarNames, and Value is the value labeling/2
% assigned to the corresponding clpfd variable.
build_assignment([], _, _, []).
build_assignment([Key|Keys], VarMap, VarNames, [Display=Val | Rest]) :-
    get_assoc_key(Key, VarMap, V),
    Val = V,
    ( var(Key), find_var_name(Key, VarNames, Name) ->
        Display = Name
    ;   Display = Key
    ),
    build_assignment(Keys, VarMap, VarNames, Rest).

find_var_name(Key, [Name=Var|_], Name) :-
    Var == Key, !.
find_var_name(Key, [_|T], Name) :-
    find_var_name(Key, T, Name).

%% ---------------------------------------------------------------------------
%% End of module
%% ---------------------------------------------------------------------------
