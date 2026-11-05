% =============================================================================
% qclp -> QUBO COMPILER  (Phase 1 + Phase 2)
% =============================================================================
% Compiles a qclp problem_spec/1 (the same finite-domain constraint language
% used by evaluator.pl / clpfd_evaluator.pl) into a QUBO (Quadratic
% Unconstrained Binary Optimization) problem, suitable for quantum/classical
% annealers.
%
% ENCODING
%   Each fd_domain(Key, Lo, Hi) variable is encoded as a "one-hot" block of
%   (Hi-Lo+1) binary variables b(Key,Lo)..b(Key,Hi), exactly one of which is
%   1. This makes most qclp constraints (fd_eq, fd_neq, fd_lt, fd_le,
%   fdalldifferent, and fdsumeq/fd_sum_eq/fd_product_eq with at most two
%   *variable* operands) translate directly into QUADRATIC penalty terms
%   with no auxiliary variables.
%
%   "Clue" constraints -- a HARD fd_eq(Var, Const) where Var has an
%   fd_domain/3 declaration and Const is a literal integer in range -- are
%   handled by pre-processing: Var is fixed to Const and removed from the
%   one-hot encoding entirely (no penalty terms, fewer binary variables).
%
%   PHASE 2: constraints needing THREE independent one-hot blocks at once
%   (e.g. fdsumeq(X, CarryVar, Y) as in send_more_money-style carry chains)
%   produce CUBIC monomials b_I*b_J*b_K. Each such monomial is reduced to a
%   quadratic term via a Rosenberg substitution: an auxiliary binary
%   variable A = b_I*b_J is introduced (and reused for every occurrence of
%   the same (I,J) pair, across the whole compile), with a penalty
%   P_aux*(3A - 2*A*b_I - 2*A*b_J + b_I*b_J) that is 0 iff A=b_I AND b_J.
%   The cubic monomial then becomes the quadratic term A*b_K. See
%   triple_viol/5 and reduce_cubic_term/2.
%
% OBJECTIVE
%   H = P_oh   * sum_V  (one-hot penalty for V)
%     + P_aux  * sum_A  (Rosenberg substitution penalty for each aux var)
%     + P_hard * sum_C  (violation indicator for each HARD constraint C)
%     + sum_{fd_cost(W,C)} ( W * violation_indicator(C)         if W > 0
%                            W * (1 - violation_indicator(C))   if W < 0 )
%
%   Every "violation indicator" used above is, for valid one-hot
%   assignments with correctly-set aux variables, an EXACT 0/1-valued
%   expression (no approximation) -- see eq_viol/3, pairs_viol/4,
%   sumeq_viol/4, prodeq_viol/4, triple_viol/5.
%
% SCOPE
%   Fully supported: fd_eq, fd_neq, fd_lt, fd_le, fdalldifferent /
%   fd_all_different, and fdsumeq/fd_sum_eq/fdsumneq/fd_sum_neq /
%   fd_product_eq for ANY combination of operand types (literals,
%   clue-fixed vars, or genuine fd_domain variables) -- including the
%   three-variable case, which is handled via the Phase 2 cubic reduction
%   described above.
% =============================================================================
:- module(qclp_qubo, [
    compile_qubo/2,        % +FilePath, -(qubo(Const,Lin,Quad)-VarTable-NBits)
    compile_qubo/3,        % +FilePath, +Options, -Result
    qubo_write/3,          % +Result, +FilePath, +SourceName
    qubo_decode/3,         % +VarTable, +BitList, -Assignment
    qubo_energy/3,         % +Qubo, +BitList, -Energy
    qubo_valid/2,          % +VarTable, +BitList  (checks one-hot blocks)
    qubo_blocks/2          % +VarTable, -Blocks (list of lists of indices)
]).

:- use_module(library(assoc)).
:- use_module(library(pairs)).
:- use_module(library(apply)).
:- use_module(library(lists)).
:- use_module(library(yall)).
:- use_module(library(aggregate)).

:- discontiguous viol_expr/3.

%% ---------------------------------------------------------------------------
%% Reading the problem_spec/1 term
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
%% Option handling
%% ---------------------------------------------------------------------------
option_default(Key, Options, Default, Value) :-
    Opt =.. [Key, V],
    ( member(Opt, Options) -> Value = V ; Value = Default ).

%% ---------------------------------------------------------------------------
%% Top level
%% ---------------------------------------------------------------------------
compile_qubo(FilePath, Result) :-
    compile_qubo(FilePath, [], Result).

% compile_qubo(+FilePath, +Options, -(qubo(Const,Lin,Quad)-VarTable-NBits))
%   Options:
%     onehot_penalty(P)   default 4   (P_oh above)
%     hard_penalty(P)     default 8   (P_hard above)
%     aux_penalty(P)      default = onehot penalty (P_oh)
%                         (penalty weight for Rosenberg aux-variable
%                          substitution constraints, Phase 2 -- see below)
compile_qubo(FilePath, Options, qubo(Const,Lin,Quad)-VarTable-NBits) :-
    read_problem_spec(FilePath, Goals0, VarNames),
    %% Rewrite constraints that have no direct low-degree encoding
    %% (fd_min/fd_max/fd_count/fd_atmost/fd_atleast, fd_weighted_sum with
    %% 3+ terms) into exact definitions over helper variables; then
    %% narrow result domains of hard sums/products. See desugar_goals/2
    %% and presolve_domains/2.
    desugar_goals(Goals0, Goals1),
    presolve_domains(Goals1, Goals),
    check_qubo_size(Goals),
    %% Default hard penalty: larger than every soft cost combined, so no
    %% ground state can trade a hard-constraint violation for a lower
    %% cost. (It used to be a flat 8, so e.g. fd_cost(10, ...) could make
    %% breaking a hard constraint "cheaper".)
    soft_weight_total(Goals, WTot),
    DefaultHard is max(8, WTot + 1),
    option_default(hard_penalty, Options, DefaultHard, PHard),
    ( member(onehot_penalty(POh), Options) ->
        true
    ;   suggest_onehot_penalty(Goals, PHard, POh)
    ),
    ( member(aux_penalty(PAux), Options) -> true ; PAux = POh ),
    find_fixed_vars(Goals, FixedAssoc),
    build_varmap(Goals, FixedAssoc, VarMap, VarTable0, NBits0),
    onehot_terms(VarMap, POh, OhTerms),
    %% ---- Phase 2: Rosenberg cubic-reduction state ----------------------
    %% aux_state(NextIdx, PairAssoc, AuxTermsAcc, AuxTableAcc)
    %%   NextIdx     : next free binary-variable index for a new aux var
    %%   PairAssoc   : (I-J) -> AuxIdx, shared across the whole compile so
    %%                 the same (b_i,b_j) pair never gets two aux vars
    %%   AuxTermsAcc : accumulated penalty terms for aux substitutions
    %%   AuxTableAcc : accumulated auxvar(Idx,label(I,J)) VarTable entries
    empty_assoc(EmptyPairs),
    nb_setval(qclp_qubo_aux_state, aux_state(NBits0, EmptyPairs, [], [])),
    nb_setval(qclp_qubo_aux_penalty, PAux),
    goal_terms(Goals, VarMap, FixedAssoc, PHard, ConTerms),
    nb_getval(qclp_qubo_aux_state, aux_state(NBits, _, AuxTerms, AuxTableRev)),
    nb_delete(qclp_qubo_aux_state),
    nb_delete(qclp_qubo_aux_penalty),
    reverse(AuxTableRev, AuxTable),
    append(OhTerms, ConTerms, AllTerms0),
    append(AllTerms0, AuxTerms, AllTerms),
    merge_terms(AllTerms, Const, Lin, Quad),
    append(VarTable0, AuxTable, VarTableAll),
    name_var_table(VarTableAll, VarNames, VarTable).

%% ---------------------------------------------------------------------------
%% Step 0a: desugar_goals(+Goals, -Goals1)
%%
%%   Constraints with no direct low-degree one-hot encoding are rewritten
%%   into EXACT definitions over fresh helper variables, each defined by a
%%   relation over at most three one-hot blocks (which viol_expr encodes
%%   exactly):
%%     fd_min(L,M)/fd_max(L,M)  T1 = min(X1,X2), T2 = min(T1,X3), ... ; M = Tn
%%     fd_count(L,V,N)          Ei = [Xi = V] (0/1), S = E1+...+En ; N = S
%%     fd_atmost(N,L,V)         ... ; S =< N
%%     fd_atleast(N,L,V)        ... ; S >= N
%%     fd_weighted_sum(Ps,T)    (3+ terms) S2 = W1*X1+W2*X2, S3 = S2+W3*X3,
%%                              ... ; Sn = T
%%   Helper domains are exactly the reachable values. Each helper is a
%%   function of its inputs, so its defining constraints (always hard)
%%   can always be met. Inside fd_cost(W, C) only the final comparison is
%%   soft -- so these constraints now work as costs too.
%%   Helper names start with '_qclp_'.
%% ---------------------------------------------------------------------------
desugar_goals(Goals0, Goals) :-
    nb_setval(qclp_aux_counter, 0),
    desugar_list(Goals0, Goals0, [], Goals).

desugar_list([], _, _, []).
desugar_list([G|Gs], All, Aux0, Out) :-
    (   G = fd_cost(W, C), needs_desugar(C)
    ->  desugar_con(C, All, Aux0, Aux1, Defs, Core),
        append(Defs, [fd_cost(W, Core)], Here)
    ;   needs_desugar(G)
    ->  desugar_con(G, All, Aux0, Aux1, Defs, Core),
        append(Defs, [Core], Here)
    ;   Here = [G], Aux1 = Aux0
    ),
    desugar_list(Gs, All, Aux1, Rest),
    append(Here, Rest, Out).

needs_desugar(fd_min(_,_)).
needs_desugar(fd_max(_,_)).
needs_desugar(fd_count(_,_,_)).
needs_desugar(fd_atmost(_,_,_)).
needs_desugar(fd_atleast(_,_,_)).
needs_desugar(fd_weighted_sum(Ps,_)) :- is_list(Ps), length(Ps, N), N >= 3.

%% desugar_con(+C, +AllGoals, +Aux0, -Aux, -Defs, -Core)
%%   Aux is a list of HelperName-Values for helpers made so far.
desugar_con(fd_min(L, M), All, A0, A, Defs, fd_eq(M, T)) :- !,
    fold_fn(min, L, fd_min(L,M), All, A0, A, Defs, T).
desugar_con(fd_max(L, M), All, A0, A, Defs, fd_eq(M, T)) :- !,
    fold_fn(max, L, fd_max(L,M), All, A0, A, Defs, T).
desugar_con(fd_count(L, V, N), All, A0, A, Defs, fd_eq(N, S)) :- !,
    count_sum(L, V, All, A0, A, Defs, S).
desugar_con(fd_atmost(N, L, V), All, A0, A, Defs, fd_le(S, N)) :- !,
    count_sum(L, V, All, A0, A, Defs, S).
desugar_con(fd_atleast(N, L, V), All, A0, A, Defs, fd_le(N, S)) :- !,
    count_sum(L, V, All, A0, A, Defs, S).
desugar_con(fd_weighted_sum(Ps, T), All, A0, A, Defs, fd_eq(S, T)) :- !,
    maplist(weight_pair, Ps, WXs),
    WXs = [W1-X1, W2-X2 | Rest],
    helper(wsum(W1,W2), X1, X2, All, A0, A1, D1, S1),
    fold_wsum(Rest, S1, All, A1, A, D2, S),
    append(D1, D2, Defs).

weight_pair(W*X, W-X) :- integer(W), !.
weight_pair(W-X, W-X) :- integer(W), !.
weight_pair(P, _) :-
    throw(error(type_error(weight_pair, P), context(fd_weighted_sum/2, 'expected W*X with integer W'))).

fold_wsum([], S, _, A, A, [], S).
fold_wsum([W-X|Rest], S0, All, A0, A, Defs, S) :-
    helper(wsum(1,W), S0, X, All, A0, A1, D1, S1),
    fold_wsum(Rest, S1, All, A1, A, D2, S),
    append(D1, D2, Defs).

fold_fn(_, [], C, _, _, _, _, _) :-
    throw(error(domain_error(non_empty_list, C), context(compile_qubo/3, 'empty list'))).
fold_fn(_, [X], _, _, A, A, [], X) :- !.
fold_fn(F, [X, Y | Rest], C, All, A0, A, Defs, T) :-
    helper(F, X, Y, All, A0, A1, D1, T1),
    fold_fn(F, [T1 | Rest], C, All, A1, A, D2, T),
    append(D1, D2, Defs).

%% count_sum(+List, +V, ...): S = number of List elements equal to V
count_sum(L, V, All, A0, A, Defs, S) :-
    count_inds(L, V, All, A0, A1, D1, Es),
    sum_chain(Es, All, A1, A, D2, S),
    append(D1, D2, Defs).

count_inds([], _, _, A, A, [], []).
count_inds([X|Xs], V, All, A0, A, Defs, [E|Es]) :-
    helper(eqind, X, V, All, A0, A1, D1, E),
    count_inds(Xs, V, All, A1, A, D2, Es),
    append(D1, D2, Defs).

sum_chain([], _, A, A, [], 0).
sum_chain([E], _, A, A, [], E) :- !.
sum_chain([E1, E2 | Es], All, A0, A, Defs, S) :-
    helper(wsum(1,1), E1, E2, All, A0, A1, D1, S1),
    sum_chain([S1 | Es], All, A1, A, D2, S),
    append(D1, D2, Defs).

%% helper(+F, +X, +Y, ..., -Defs, -Z): Z = F(X, Y). If the result can
%% only take one value it is returned as a constant (no helper needed).
helper(F, X, Y, All, A0, A, Defs, Z) :-
    term_values(X, All, A0, XVs), term_values(Y, All, A0, YVs),
    findall(V, ( member(Xv, XVs), member(Yv, YVs), qclp_fn_value(F, Xv, Yv, V) ), Vs0),
    sort(Vs0, Vs),
    (   Vs = [Single]
    ->  Z = Single, Defs = [], A = A0
    ;   nb_getval(qclp_aux_counter, N0), N is N0 + 1, nb_setval(qclp_aux_counter, N),
        functor(F, FN, _),
        format(atom(Z), "_qclp_~w~w", [FN, N]),
        Defs = [fd_domain(Z, Vs), '$qclp_fn'(F, X, Y, Z)],
        A = [Z-Vs | A0]
    ).

%% term_values(+Term, +AllGoals, +Aux, -Values)
term_values(T, _, _, [T]) :- integer(T), !.
term_values(T, _, Aux, Vs) :- atom(T), memberchk(T-Vs, Aux), !.
term_values(T, All, _, Vs) :- find_domain_vals(T, All, Vs), !.
term_values(T, _, _, _) :-
    format(string(Msg), "~q is used in a constraint but has no fd_domain declaration", [T]),
    throw(error(existence_error(fd_variable, T), context(compile_qubo/3, Msg))).

%% ---------------------------------------------------------------------------
%% Step 0b: presolve_domains(+Goals, -Goals1)
%%   For each HARD fdsumeq/fd_sum_eq/fd_product_eq whose result Z is a
%%   declared variable, Z's domain is narrowed to the values X op Y can
%%   actually take (repeated until nothing changes). This removes only
%%   values that no solution can use, so it never changes the answer --
%%   but it keeps one-hot blocks small (prob5's partial sums were
%%   declared 0..1000, i.e. 1001-bit blocks, and the compile ran out of
%%   stack; they reach only a handful of values).
%% ---------------------------------------------------------------------------
presolve_domains(Goals, Out) :-
    presolve_pass(Goals, 10, Out).

presolve_pass(Goals, 0, Goals) :- !.
presolve_pass(Goals, K, Out) :-
    narrow_once(Goals, Goals, Goals1, Changed),
    (   Changed == true -> K1 is K - 1, presolve_pass(Goals1, K1, Out)
    ;   Out = Goals1
    ).

narrow_once([], Cur, Cur, false).
narrow_once([G|Gs], Cur, Out, Changed) :-
    (   sum_like(G, Op, X, Y, Z), \+ integer(Z),
        find_domain_vals(Z, Cur, ZVs),
        term_values_opt(X, Cur, XVs), term_values_opt(Y, Cur, YVs),
        findall(V, ( member(A, XVs), member(B, YVs), apply_op(Op, A, B, V) ), Vs0),
        sort(Vs0, Reach),
        ord_intersection(ZVs, Reach, New),
        New \== [], New \== ZVs
    ->  replace_domain(Cur, Z, New, Cur1),
        narrow_once(Gs, Cur1, Out, _), Changed = true
    ;   narrow_once(Gs, Cur, Out, Changed)
    ).

sum_like(fdsumeq(X,Y,Z), add, X, Y, Z).
sum_like(fd_sum_eq(X,Y,Z), add, X, Y, Z).
sum_like(fd_product_eq(X,Y,Z), mul, X, Y, Z).
apply_op(add, A, B, V) :- V is A + B.
apply_op(mul, A, B, V) :- V is A * B.

term_values_opt(T, _, [T]) :- integer(T), !.
term_values_opt(T, Goals, Vs) :- find_domain_vals(T, Goals, Vs).

%% replace_domain(+Goals, +Key, +Vals, -Goals1): Key's first fd_domain
%% goal becomes fd_domain(Key, Vals). Recursion, not findall, so that
%% Prolog-variable keys keep their identity.
replace_domain([], _, _, []).
replace_domain([G|Gs], K, Vs, [G1|Gs1]) :-
    (   ( G = fd_domain(K2,_,_) ; G = fd_domain(K2,_) ), K2 == K
    ->  G1 = fd_domain(K2, Vs), Gs1 = Gs
    ;   G1 = G, replace_domain(Gs, K, Vs, Gs1)
    ).

%% ---------------------------------------------------------------------------
%% Step 0c: check_qubo_size(+Goals) -- a clear error instead of running
%% out of memory: at most 4096 one-hot bits in total.
%% ---------------------------------------------------------------------------
check_qubo_size(Goals) :-
    domain_sizes(Goals, Sizes),
    sum_list(Sizes, Bits),
    (   Bits > 4096
    ->  format(string(Msg), "the one-hot encoding would need ~w bits (limit 4096); narrow the domains", [Bits]),
        throw(error(resource_error(qubo_size), context(compile_qubo/3, Msg)))
    ;   true
    ).

domain_sizes([], []).
domain_sizes([G|Gs], Sizes) :-
    (   G = fd_domain(_, Lo, Hi), integer(Lo), integer(Hi) -> S is Hi - Lo + 1, Sizes = [S|Rest]
    ;   G = fd_domain(_, L), is_list(L) -> expand_domain_list(L, Vs), length(Vs, S), Sizes = [S|Rest]
    ;   Sizes = Rest
    ),
    domain_sizes(Gs, Rest).

%% soft_weight_total(+Goals, -Total): sum of |W| over all fd_cost goals
soft_weight_total(Goals, Total) :-
    foldl([G, A0, A]>>( G = fd_cost(W, _), number(W) -> A is A0 + abs(W) ; A = A0 ), Goals, 0, Total).

%% ---------------------------------------------------------------------------
%% Step 1: clue detection  (hard fd_eq(Var,Const) with Var in fd_domain range)
%% ---------------------------------------------------------------------------
% find_fixed_vars(+Goals, -FixedAssoc)
%   FixedAssoc maps Key -> IntVal for every Key that is fixed by a hard
%   fd_eq(Key,Const) or fd_eq(Const,Key) goal, where Const is an integer
%   within Key's declared fd_domain/3 range. (fd_cost-wrapped fd_eq's do
%   NOT cause fixing, since they are soft preferences, not requirements.)
find_fixed_vars(Goals, FixedAssoc) :-
    empty_assoc(Empty),
    foldl(maybe_fix_var(Goals), Goals, Empty, FixedAssoc).

maybe_fix_var(Goals, fd_eq(K, C), AssocIn, AssocOut) :-
    integer(C), find_domain_vals(K, Goals, Vals), memberchk(C, Vals), !,
    put_assoc(K, AssocIn, C, AssocOut).
maybe_fix_var(Goals, fd_eq(C, K), AssocIn, AssocOut) :-
    integer(C), find_domain_vals(K, Goals, Vals), memberchk(C, Vals), !,
    put_assoc(K, AssocIn, C, AssocOut).
maybe_fix_var(_, _, Assoc, Assoc).

%% find_domain(+K, +Goals, -Lo, -Hi)
%%   For contiguous domains only (backward compat for callers that need Lo/Hi).
find_domain(K, Goals, Lo, Hi) :-
    member(fd_domain(K2, Lo, Hi), Goals), K2 == K,
    integer(Lo), integer(Hi), !.

%% find_domain_vals(+K, +Goals, -Vals)
%%   Returns the sorted value list for any fd_domain form.
find_domain_vals(K, Goals, Vals) :-
    member(Goal, Goals), Goal =.. [fd_domain, K2 | DomSpec], K2 == K, !,
    ( DomSpec = [Lo,Hi], integer(Lo), integer(Hi) ->
        numlist(Lo, Hi, Vals)
    ; DomSpec = [ValList], is_list(ValList) ->
        expand_domain_list(ValList, Vals)
    ).
find_domain_vals(K, Goals, Vals) :-
    member(fd_domain(K2, ValList), Goals), K2 == K, is_list(ValList), !,
    expand_domain_list(ValList, Vals).

%% ---------------------------------------------------------------------------
%% suggest_onehot_penalty(+Goals, +PHard, -POh)
%%   A heuristic default for P_oh, the one-hot penalty weight: it must be
%%   large enough that breaking any single variable's "exactly one" block
%%   (which increases the one-hot penalty by P_oh*k^2 for k extra bits set)
%%   can never be offset by the corresponding increase in P_hard-weighted
%%   constraint terms (each such term has magnitude <= P_hard, and an extra
%%   bit can activate at most one such term per constraint-reference per
%%   value of the OTHER variable's domain). We use:
%%      P_oh = P_hard * (MaxDomainSize - 1) * MaxDegree
%%   where MaxDomainSize is the largest fd_domain/3 range and MaxDegree is
%%   the largest number of (non-fd_domain) goals referencing any single
%%   variable. This is deliberately generous (favours a feasible one-hot
%%   encoding over a tight QUBO), and can always be overridden via the
%%   onehot_penalty(P) option.
%% ---------------------------------------------------------------------------
suggest_onehot_penalty(Goals, PHard, POh) :-
    findall(Size,
        ( member(Goal, Goals),
          ( Goal = fd_domain(_,Lo,Hi), integer(Lo), integer(Hi)
          -> Size is Hi-Lo+1
          ; Goal = fd_domain(_,Vals), is_list(Vals)
          -> length(Vals, Size)
          )
        ), Sizes),
    ( Sizes == [] -> MaxSize = 1 ; max_list(Sizes, MaxSize) ),
    %% Use exclude/3 (NOT findall) so NonDomainGoals contains the
    %% ORIGINAL goal terms from Goals, preserving variable identity
    %% (Prolog variable keys in e.g. fd_domain(Q0,0,3) must be the
    %% same objects that appear in fdsumneq(Q0,...) -- findall copies
    %% its template, breaking that identity).
    exclude([G]>>(G=fd_domain(_,_,_) ; G=fd_domain(_,_)), Goals, NonDomainGoals),
    findall(Deg,
        ( member(Goal, Goals),
          ( Goal = fd_domain(Key,_,_) ; Goal = fd_domain(Key,_) ),
          aggregate_all(count, ( member(G,NonDomainGoals), term_contains_var(G,Key) ), Deg)
        ),
        Degs),
    ( Degs == [] -> MaxDeg = 1 ; max_list(Degs, MaxDeg0), MaxDeg = max(MaxDeg0,1) ),
    POh is PHard * max(MaxSize-1,1) * MaxDeg.

% term_contains_var(+Term, +Key) : true if Key occurs (==) anywhere in Term.
term_contains_var(Term, Key) :- Term == Key, !.
term_contains_var(Term, Key) :-
    compound(Term), arg(_,Term,Arg), term_contains_var(Arg,Key), !.

%% expand_domain_list(+RawList, -Vals)
%%   Expands a mixed list of integers and Lo-Hi range pairs into
%%   a flat sorted deduplicated list of integer values.
%%   e.g. [1-3, 5-7, 10]  -->  [1,2,3,5,6,7,10]
%%        [0, 5, 10]       -->  [0,5,10]
%%        [0-2, 5]         -->  [0,1,2,5]
expand_domain_list(Raw, Vals) :-
    maplist(expand_domain_element, Raw, Chunks),
    flatten(Chunks, Flat),
    sort(Flat, Vals).           %% sort also deduplicates

expand_domain_element(Lo-Hi, Vals) :- !,
    integer(Lo), integer(Hi), Lo =< Hi,
    numlist(Lo, Hi, Vals).
expand_domain_element(V, [V]) :- integer(V).
% build_varmap(+Goals, +FixedAssoc, -VarMap, -VarTable, -NBits)
%   VarMap maps Key -> bits(Lo,Hi,Base)  for non-fixed domain vars
%                 or -> fixed(Val)       for clue-fixed vars
%   VarTable is a list of bitvar(Index,Key,Value) / fixedvar(Key,Value)
%   entries (display names attached later by name_var_table/3).
build_varmap(Goals, FixedAssoc, VarMap, VarTable, NBits) :-
    empty_assoc(EmptyMap),
    build_varmap_(Goals, FixedAssoc, 0, EmptyMap, VarMap, [], VarTable0, NBits),
    reverse(VarTable0, VarTable).

build_varmap_([], _, NBits, VarMap, VarMap, VarTable, VarTable, NBits).
build_varmap_([fd_domain(Key,Lo,Hi)|T], FixedAssoc, BaseIn, MapIn, MapOut, TabIn, TabOut, NBits) :-
    integer(Lo), integer(Hi), !,
    ( get_assoc(Key, FixedAssoc, Val) ->
        put_assoc(Key, MapIn, fixed(Val), MapMid),
        TabMid = [fixedvar(Key,Val) | TabIn],
        BaseMid = BaseIn
    ;   put_assoc(Key, MapIn, bits(Lo,Hi,BaseIn), MapMid),
        numlist(Lo, Hi, Vals),
        maplist(make_bitvar(BaseIn,Lo,Key), Vals, NewEntries),
        append(NewEntries, TabIn, TabMid),
        Size is Hi-Lo+1,
        BaseMid is BaseIn + Size
    ),
    build_varmap_(T, FixedAssoc, BaseMid, MapMid, MapOut, TabMid, TabOut, NBits).
build_varmap_([fd_domain(Key,ValList)|T], FixedAssoc, BaseIn, MapIn, MapOut, TabIn, TabOut, NBits) :-
    is_list(ValList), !,
    expand_domain_list(ValList, Vals),           %% handles Lo-Hi ranges
    ( get_assoc(Key, FixedAssoc, Val) ->
        put_assoc(Key, MapIn, fixed(Val), MapMid),
        TabMid = [fixedvar(Key,Val) | TabIn],
        BaseMid = BaseIn
    ;   put_assoc(Key, MapIn, bits(vals(Vals),BaseIn), MapMid),
        maplist(make_bitvar_sparse(BaseIn,Key,Vals), Vals, NewEntries),
        append(NewEntries, TabIn, TabMid),
        length(Vals, Size),
        BaseMid is BaseIn + Size
    ),
    build_varmap_(T, FixedAssoc, BaseMid, MapMid, MapOut, TabMid, TabOut, NBits).
build_varmap_([_|T], FixedAssoc, BaseIn, MapIn, MapOut, TabIn, TabOut, NBits) :-
    build_varmap_(T, FixedAssoc, BaseIn, MapIn, MapOut, TabIn, TabOut, NBits).

make_bitvar(Base,Lo,Key,V,bitvar(Idx,Key,V)) :- Idx is Base+(V-Lo).
make_bitvar_sparse(Base,Key,Vals,V,bitvar(Idx,Key,V)) :-
    nth0(K,Vals,V), Idx is Base+K.

%% ---------------------------------------------------------------------------
%% Step 3: one-hot penalty terms
%% ---------------------------------------------------------------------------
% For each non-fixed variable V with one-hot block of size N (indices
% Base..Base+N-1):
%   P_oh * (sum_v b_v - 1)^2  =  P_oh * ( -sum_v b_v + 2*sum_{v<w} b_v b_w + 1 )
onehot_terms(VarMap, POh, Terms) :-
    assoc_to_list(VarMap, Pairs),
    findall(Ts,
        ( member(_-Entry, Pairs),
          ( Entry = bits(Lo,Hi,Base), integer(Lo), integer(Hi) ->
              onehot_terms_for(Lo,Hi,Base,POh,Ts)
          ; Entry = bits(vals(Vals),Base) ->
              length(Vals,N), Top is Base+N-1,
              onehot_terms_for_range(Base,Top,POh,Ts)
          )
        ), TermLists),
    flatten(TermLists, Terms).

onehot_terms_for(Lo,Hi,Base,POh,Terms) :-
    N is Hi-Lo+1,
    Top is Base+N-1,
    onehot_terms_for_range(Base,Top,POh,Terms).

onehot_terms_for_range(Base,Top,POh,Terms) :-
    findall(term(lin,I,LC), ( between(Base,Top,I), LC is -POh ), LinTerms),
    findall(term(quad,I,J,QC),
        ( between(Base,Top,I), between(Base,Top,J), I<J, QC is 2*POh ),
        QuadTerms),
    append([term(const,POh)|LinTerms], QuadTerms, Terms).

%% ---------------------------------------------------------------------------
%% Operand resolution
%% ---------------------------------------------------------------------------
% resolve_operand(+Term, +VarMap, -Op)
%   Op = const(IntVal)              -- a literal integer, or a clue-fixed var
%      | var(Key,DomSpec,Base)      -- a one-hot encoded variable, where
%                                       DomSpec = rng(Lo,Hi)  (contiguous)
%                                              | vals(Vals)   (sparse list)
%      | unknown(Term)              -- neither a number nor a declared key
resolve_operand(Term, _VarMap, const(Term)) :- number(Term), !.
resolve_operand(Term, VarMap, Op) :-
    ( get_assoc(Term, VarMap, Entry) ->
        ( Entry = fixed(Val) -> Op = const(Val)
        ; Entry = bits(Lo,Hi,Base), integer(Lo), integer(Hi) ->
            Op = var(Term, rng(Lo,Hi), Base)
        ; Entry = bits(vals(Vals),Base) ->
            Op = var(Term, vals(Vals), Base)
        )
    ;   Op = unknown(Term)
    ).

contains_unknown(Ops) :- member(unknown(_), Ops).

%% ---------------------------------------------------------------------------
%% Domain helpers -- abstract over rng (contiguous) and vals (sparse) domains.
%%   All var operands are now uniformly var(Key, DomSpec, Base) -- 3 args.
%% ---------------------------------------------------------------------------

%% is_domain_var(+Op) -- true iff Op is a var/3 domain operand
is_domain_var(var(_,_,_)).

%% domain_element(+Op, -Val, -Idx) : enumerate (value, bit-index) pairs
domain_element(var(_,rng(Lo,Hi),Base), V, Idx) :-
    between(Lo, Hi, V),
    Idx is Base + (V - Lo).
domain_element(var(_,vals(Vals),Base), V, Idx) :-
    nth0(K, Vals, V),
    Idx is Base + K.

%% domain_member(+Op, +Val) : true if Val is in Op's domain
domain_member(var(_,rng(Lo,Hi),_), V) :- between(Lo,Hi,V).
domain_member(var(_,vals(Vals),_), V) :- member(V, Vals).

%% domain_idx(+Op, +Val, -Idx) : bit index for Val in Op's one-hot block
domain_idx(var(_,rng(Lo,_),Base), V, Idx) :- !, Idx is Base+(V-Lo).
domain_idx(var(_,vals(Vals),Base), V, Idx) :- nth0(K,Vals,V), Idx is Base+K.

%% ---------------------------------------------------------------------------
%% viol(Const, LinTerms, QuadTerms, CubicTerms) algebra
%%   LinTerms   = list of lin(Index,Coeff)
%%   QuadTerms  = list of quad(I,J,Coeff), I<J
%%   CubicTerms = list of cubic(I,J,K,Coeff), I<J<K  (Phase 2)
%%   "unsupported(Why)" propagates through all operations.
%%
%%   For backward compatibility, viol(C,L,Q) (3-arity, no cubic terms) is
%%   still accepted everywhere and is equivalent to viol(C,L,Q,[]).
%% ---------------------------------------------------------------------------
complement_viol(unsupported(W), unsupported(W)) :- !.
complement_viol(viol(C,L,Q), viol(C2,L2,Q2,[])) :- !,
    C2 is 1-C,
    maplist(negate_lin, L, L2),
    maplist(negate_quad, Q, Q2).
complement_viol(viol(C,L,Q,Cu), viol(C2,L2,Q2,Cu2)) :-
    C2 is 1-C,
    maplist(negate_lin, L, L2),
    maplist(negate_quad, Q, Q2),
    maplist(negate_cubic, Cu, Cu2).
negate_lin(lin(I,C), lin(I,C2)) :- C2 is -C.
negate_quad(quad(I,J,C), quad(I,J,C2)) :- C2 is -C.
negate_cubic(cubic(I,J,K,C), cubic(I,J,K,C2)) :- C2 is -C.

scale_viol(unsupported(W), _, unsupported(W)) :- !.
scale_viol(viol(C,L,Q), F, viol(C2,L2,Q2,[])) :- !,
    C2 is C*F,
    maplist(scale_lin(F), L, L2),
    maplist(scale_quad(F), Q, Q2).
scale_viol(viol(C,L,Q,Cu), F, viol(C2,L2,Q2,Cu2)) :-
    C2 is C*F,
    maplist(scale_lin(F), L, L2),
    maplist(scale_quad(F), Q, Q2),
    maplist(scale_cubic(F), Cu, Cu2).
scale_lin(F, lin(I,C), lin(I,C2)) :- C2 is C*F.
scale_quad(F, quad(I,J,C), quad(I,J,C2)) :- C2 is C*F.
scale_cubic(F, cubic(I,J,K,C), cubic(I,J,K,C2)) :- C2 is C*F.

add_viol(unsupported(W), _, unsupported(W)) :- !.
add_viol(_, unsupported(W), unsupported(W)) :- !.
add_viol(viol(C1,L1,Q1), viol(C2,L2,Q2), viol(C3,L3,Q3,Cu3)) :- !,
    C3 is C1+C2, append(L1,L2,L3), append(Q1,Q2,Q3), Cu3=[].
add_viol(V1, V2, viol(C3,L3,Q3,Cu3)) :-
    to_viol4(V1, viol(C1,L1,Q1,Cu1)),
    to_viol4(V2, viol(C2,L2,Q2,Cu2)),
    C3 is C1+C2, append(L1,L2,L3), append(Q1,Q2,Q3), append(Cu1,Cu2,Cu3).

% to_viol4(+Viol3or4, -Viol4) : normalize 3-arity viol/3 to viol/4 with [].
to_viol4(viol(C,L,Q), viol(C,L,Q,[])) :- !.
to_viol4(viol(C,L,Q,Cu), viol(C,L,Q,Cu)).

viol_to_terms(unsupported(_), []).
viol_to_terms(viol(C,L,Q), Terms) :- !, viol_to_terms(viol(C,L,Q,[]), Terms).
viol_to_terms(viol(C,L,Q,Cu), Terms) :-
    findall(term(const,C), C =\= 0, ConstTerms0),
    ( C =:= 0 -> ConstTerms = [] ; ConstTerms = ConstTerms0 ),
    maplist([lin(I,Cf),term(lin,I,Cf)]>>true, L, LinTerms),
    maplist([quad(I,J,Cf),term(quad,I,J,Cf)]>>true, Q, QuadTerms),
    maplist(reduce_cubic_term, Cu, CubicTermLists),
    flatten(CubicTermLists, CubicTerms),
    append([ConstTerms,LinTerms,QuadTerms,CubicTerms], Terms).

%% ---------------------------------------------------------------------------
%% reduce_cubic_term(+cubic(I,J,K,Coeff), -Terms)   -- Rosenberg reduction
%%   (Phase 2)
%%
%%   Replaces  Coeff * b_I * b_J * b_K  (I,J,K distinct binary-variable
%%   indices) with quadratic terms by introducing (or reusing) an
%%   auxiliary binary variable A standing for b_I * b_J, plus a penalty
%%   enforcing that substitution:
%%
%%     P_aux * ( 3*A - 2*A*b_I - 2*A*b_J + b_I*b_J )
%%
%%   This penalty is exactly 0 when A = b_I AND b_J (i.e. A=1 iff both
%%   b_I=b_J=1), and is a positive integer (>= P_aux) for every other
%%   combination of (A,b_I,b_J) -- so for P_aux large enough it forces
%%   A = b_I*b_J at the optimum. The same (I,J) pair always reuses the
%%   same aux variable (via the global PairAssoc), so e.g. all three
%%   pairings of a cubic term (I,J,K) sharing one factor only ever
%%   allocate at most 3 aux variables total across an entire compile.
%%
%%   The reduced cubic term then becomes the quadratic term
%%     Coeff * A * b_K
%%   (A < K or K < A as required by the I<J convention on quad terms).
%%
%%   Terms = [ term(quad, A, K, Coeff) | <P_aux substitution terms> ]
%% ---------------------------------------------------------------------------
reduce_cubic_term(cubic(I,J,K,Coeff), Terms) :-
    get_aux_var(I, J, A, SubTerms),
    ( A < K -> Terms = [term(quad,A,K,Coeff)|SubTerms]
    ; K < A -> Terms = [term(quad,K,A,Coeff)|SubTerms]
    ;   %% A == K should never happen (A is a fresh/aux index, distinct
        %% from every original variable index, including K); guard anyway.
        throw(error(domain_error(distinct_aux_and_var,A=K), reduce_cubic_term/2))
    ).

% get_aux_var(+I, +J, -A, -SubTerms)
%   Looks up (or allocates) the aux variable A for the pair (I,J)
%   (I<J normalized internally), reading/updating the global
%   qclp_qubo_aux_state. SubTerms is [] if the aux var (and its
%   substitution penalty terms) already existed; otherwise it is the
%   list of penalty terms for  P_aux*(3A - 2*A*b_I - 2*A*b_J + b_I*b_J).
get_aux_var(I0, J0, A, SubTerms) :-
    ( I0 < J0 -> I=I0, J=J0 ; I=J0, J=I0 ),
    nb_getval(qclp_qubo_aux_state, aux_state(Next, Pairs, Terms, Tab)),
    nb_getval(qclp_qubo_aux_penalty, PAux),
    ( get_assoc(I-J, Pairs, A) ->
        SubTerms = []
    ;   A = Next,
        Next1 is Next+1,
        put_assoc(I-J, Pairs, A, Pairs1),
        C3 is 3*PAux, CM2 is -2*PAux,
        %% A is always allocated after I and J, so A > I and A > J.
        SubTerms = [ term(lin,A,C3),
                     term(quad,I,A,CM2),
                     term(quad,J,A,CM2),
                     term(quad,I,J,PAux) ],
        append(Terms, SubTerms, Terms1),
        Tab1 = [auxvar(A,pair(I,J))|Tab],
        nb_setval(qclp_qubo_aux_state, aux_state(Next1, Pairs1, Terms1, Tab1))
    ).

%% ---------------------------------------------------------------------------
%% eq_viol / neq (via complement)
%%   eq_viol(OpX,OpY,Viol):  Viol = indicator( X != Y )
%%     (this is the violation indicator for a HARD fd_eq(X,Y) constraint)
%% ---------------------------------------------------------------------------
eq_viol(OpX,OpY,Viol) :-
    ( OpX = var(KX,_,_), OpY = var(KY,_,_), KX==KY ->
        Viol = viol(0,[],[])
    ; OpX = const(A), OpY = const(B) ->
        ( A =:= B -> Viol = viol(0,[],[]) ; Viol = viol(1,[],[]) )
    ; OpX = const(A), is_domain_var(OpY) ->
        ( domain_idx(OpY, A, IdxA) ->
            Viol = viol(1,[lin(IdxA,-1)],[])
        ;   Viol = viol(1,[],[])
        )
    ; is_domain_var(OpX), OpY = const(B) ->
        ( domain_idx(OpX, B, IdxB) ->
            Viol = viol(1,[lin(IdxB,-1)],[])
        ;   Viol = viol(1,[],[])
        )
    ; is_domain_var(OpX), is_domain_var(OpY) ->
        findall(quad(I,J,-1),
            ( domain_element(OpX,A,IA), domain_element(OpY,A,IB),
              ( IA<IB -> I=IA,J=IB ; I=IB,J=IA )
            ),
            QuadTerms),
        Viol = viol(1,[],QuadTerms)
    ;   Viol = unsupported(eq(OpX,OpY))
    ).

%% ---------------------------------------------------------------------------
%% pairs_viol(OpX,OpY,Pred,Viol)
%%   Viol = indicator( exists violating pair (a,b), call(Pred,a,b) true,
%%                      such that X=a and Y=b )
%%   Used directly for fd_lt / fd_le, and as a building block for
%%   sumeq_viol / prodeq_viol's 2-variable cases.
%% ---------------------------------------------------------------------------
pairs_viol(OpX,OpY,Pred,Viol) :-
    ( OpX=const(A), OpY=const(B) ->
        ( call(Pred,A,B) -> Viol=viol(1,[],[]) ; Viol=viol(0,[],[]) )
    ; OpX=const(A), is_domain_var(OpY) ->
        findall(lin(Idx,1),
            ( domain_element(OpY,B,Idx), call(Pred,A,B) ),
            Lin),
        Viol=viol(0,Lin,[])
    ; is_domain_var(OpX), OpY=const(B) ->
        findall(lin(Idx,1),
            ( domain_element(OpX,A,Idx), call(Pred,A,B) ),
            Lin),
        Viol=viol(0,Lin,[])
    ; is_domain_var(OpX), is_domain_var(OpY) ->
        findall(T,
            ( domain_element(OpX,A,IA), domain_element(OpY,B,IB),
              call(Pred,A,B),
              ( IA==IB -> T=lin(IA,1)
              ; IA<IB -> T=quad(IA,IB,1)
              ;          T=quad(IB,IA,1) )
            ),
            Terms),
        partition([Tm]>>(Tm=lin(_,_)), Terms, Lin, Quad),
        Viol=viol(0,Lin,Quad)
    ;   Viol=unsupported(pairs(OpX,OpY))
    ).

%% ---------------------------------------------------------------------------
%% sumeq_viol(OpX,OpK,OpY,Viol):  Viol = indicator( X + K != Y )
%%   (used directly for fdsumeq/3 and, with relabelling, fd_sum_eq/3)
%% ---------------------------------------------------------------------------
%% classify(+Op, -IsVar)
classify(Op,1) :- is_domain_var(Op), !.
classify(_,0).
op_value(const(V),V).

sumeq_viol(OpX,OpK,OpY,Viol) :-
    classify(OpX,CX), classify(OpK,CK), classify(OpY,CY),
    NVars is CX+CK+CY,
    ( NVars =:= 0 ->
        op_value(OpX,A), op_value(OpK,K), op_value(OpY,B),
        ( A+K =\= B -> Viol=viol(1,[],[]) ; Viol=viol(0,[],[]) )
    ; NVars =:= 1, is_domain_var(OpX) ->
        op_value(OpK,K), op_value(OpY,B),
        findall(lin(Idx,1), ( domain_element(OpX,A,Idx), A+K=\=B ), Lin),
        Viol=viol(0,Lin,[])
    ; NVars =:= 1, is_domain_var(OpK) ->
        op_value(OpX,A), op_value(OpY,B),
        findall(lin(Idx,1), ( domain_element(OpK,K,Idx), A+K=\=B ), Lin),
        Viol=viol(0,Lin,[])
    ; NVars =:= 1, is_domain_var(OpY) ->
        op_value(OpX,A), op_value(OpK,K),
        findall(lin(Idx,1), ( domain_element(OpY,B,Idx), A+K=\=B ), Lin),
        Viol=viol(0,Lin,[])
    ; NVars =:= 2, is_domain_var(OpX), is_domain_var(OpK) ->
        op_value(OpY,B),
        pairs_viol(OpX,OpK,[A,K]>>(A+K=\=B),Viol)
    ; NVars =:= 2, is_domain_var(OpX), is_domain_var(OpY) ->
        op_value(OpK,K),
        pairs_viol(OpX,OpY,[A,B]>>(A+K=\=B),Viol)
    ; NVars =:= 2 ->
        %% OpK and OpY are vars, OpX is const
        op_value(OpX,A),
        pairs_viol(OpK,OpY,[K,B]>>(A+K=\=B),Viol)
    ;   %% NVars == 3: three independent one-hot blocks -> cubic (Phase 2).
        triple_viol(OpX,OpK,OpY,[A,K,B]>>(A+K=\=B),Viol)
    ).

%% ---------------------------------------------------------------------------
%% prodeq_viol(OpX,OpY,OpZ,Viol):  Viol = indicator( X * Y != Z )
%% ---------------------------------------------------------------------------
prodeq_viol(OpX,OpY,OpZ,Viol) :-
    classify(OpX,CX), classify(OpY,CY), classify(OpZ,CZ),
    NVars is CX+CY+CZ,
    ( NVars =:= 0 ->
        op_value(OpX,A), op_value(OpY,B), op_value(OpZ,Z),
        ( A*B =\= Z -> Viol=viol(1,[],[]) ; Viol=viol(0,[],[]) )
    ; NVars =:= 1, is_domain_var(OpX) ->
        op_value(OpY,B), op_value(OpZ,Z),
        findall(lin(Idx,1), ( domain_element(OpX,A,Idx), A*B=\=Z ), Lin),
        Viol=viol(0,Lin,[])
    ; NVars =:= 1, is_domain_var(OpY) ->
        op_value(OpX,A), op_value(OpZ,Z),
        findall(lin(Idx,1), ( domain_element(OpY,B,Idx), A*B=\=Z ), Lin),
        Viol=viol(0,Lin,[])
    ; NVars =:= 1, is_domain_var(OpZ) ->
        op_value(OpX,A), op_value(OpY,B),
        findall(lin(Idx,1), ( domain_element(OpZ,Z,Idx), A*B=\=Z ), Lin),
        Viol=viol(0,Lin,[])
    ; NVars =:= 2, is_domain_var(OpX), is_domain_var(OpY) ->
        op_value(OpZ,Z),
        pairs_viol(OpX,OpY,[A,B]>>(A*B=\=Z),Viol)
    ; NVars =:= 2, is_domain_var(OpX), is_domain_var(OpZ) ->
        op_value(OpY,B),
        pairs_viol(OpX,OpZ,[A,Z]>>(A*B=\=Z),Viol)
    ; NVars =:= 2 ->
        op_value(OpX,A),
        pairs_viol(OpY,OpZ,[B,Z]>>(A*B=\=Z),Viol)
    ;   %% NVars == 3: three independent one-hot blocks -> cubic (Phase 2).
        triple_viol(OpX,OpY,OpZ,[A,B,Z]>>(A*B=\=Z),Viol)
    ).

%% ---------------------------------------------------------------------------
%% triple_viol(OpX,OpY,OpZ,Pred,Viol)   -- Phase 2 (cubic, Rosenberg-reduced)
%%   Viol = indicator( exists violating triple (a,b,c), call(Pred,a,b,c)
%%                      true, such that X=a, Y=b, Z=c )
%%   OpX, OpY, OpZ must all be var(_,Lo,Hi,Base) (three independent
%%   one-hot blocks). Each violating triple (a,b,c) contributes the
%%   monomial  b_IA * b_IB * b_IC  (the product of the three one-hot
%%   indicator bits for X=a, Y=b, Z=c respectively), which is exactly 1
%%   iff X=a AND Y=b AND Z=c, and 0 otherwise -- so the sum over all
%%   violating triples is exactly the 0/1 violation indicator for valid
%%   one-hot assignments.
%%
%%   If two (or three) of IA,IB,IC coincide (the same one-hot block index
%%   referenced twice -- can happen if e.g. X and Y are the *same*
%%   variable), the monomial degenerates to a lower-degree term (since
%%   b_I*b_I = b_I for 0/1 variables); this is handled by
%%   classify_triple/2 below rather than passed to the cubic reducer.
%% ---------------------------------------------------------------------------
triple_viol(OpX, OpY, OpZ, Pred, Viol) :-
    is_domain_var(OpX), is_domain_var(OpY), is_domain_var(OpZ), !,
    findall(Term,
        ( domain_element(OpX,A,IA), domain_element(OpY,B,IB), domain_element(OpZ,C,IC),
          call(Pred,A,B,C),
          classify_triple(IA,IB,IC,Term)
        ),
        Terms),
    partition([Tm]>>(Tm=lin(_,_)), Terms, Lin0, Rest),
    partition([Tm]>>(Tm=quad(_,_,_)), Rest, Quad0, Cubic0),
    Viol=viol(0,Lin0,Quad0,Cubic0).
triple_viol(OpX,OpY,OpZ,_,unsupported(triple(OpX,OpY,OpZ))).

% classify_triple(+IA,+IB,+IC,-Term) : given three one-hot bit indices
% (possibly with duplicates, since b_I*b_I = b_I for 0/1 variables),
% reduce  b_IA * b_IB * b_IC  to its canonical lin/quad/cubic term.
classify_triple(IA,IB,IC,Term) :-
    sort([IA,IB,IC], Sorted),
    ( Sorted = [I] -> Term = lin(I,1)
    ; Sorted = [I,J] -> Term = quad(I,J,1)
    ; Sorted = [I,J,K] -> Term = cubic(I,J,K,1)
    ).

%% ---------------------------------------------------------------------------
%% fdalldifferent(L): sum of pairwise "X==Y" indicators
%% ---------------------------------------------------------------------------
alldiff_viol(Vars, VarMap, Viol) :-
    maplist({VarMap}/[Term,Op]>>resolve_operand(Term,VarMap,Op), Vars, Ops),
    findall(PV,
        ( nth0(I,Ops,OpI), nth0(J,Ops,OpJ), I<J,
          eq_viol(OpI,OpJ,EqV),       % indicator(Vi != Vj)
          complement_viol(EqV,PV)     % indicator(Vi == Vj)  -- the violation
        ),
        PairViols),
    foldl(add_viol, PairViols, viol(0,[],[]), Viol).

%% ---------------------------------------------------------------------------
%% viol_expr(+Goal, +VarMap, -Viol)
%%   Dispatches a single constraint goal to its violation-indicator builder.
%%   Returns unsupported(Goal) for anything not handled (Phase 2, or
%%   references to undeclared identifiers).
%% ---------------------------------------------------------------------------
viol_expr(fd_eq(X,Y), VarMap, Viol) :- !,
    resolve_operand(X,VarMap,OX), resolve_operand(Y,VarMap,OY),
    ( contains_unknown([OX,OY]) -> Viol=unsupported(fd_eq(X,Y)) ; eq_viol(OX,OY,Viol) ).
viol_expr(fd_neq(X,Y), VarMap, Viol) :- !,
    resolve_operand(X,VarMap,OX), resolve_operand(Y,VarMap,OY),
    ( contains_unknown([OX,OY]) -> Viol=unsupported(fd_neq(X,Y))
    ; eq_viol(OX,OY,EV), complement_viol(EV,Viol) ).
viol_expr(fd_lt(X,Y), VarMap, Viol) :- !,
    resolve_operand(X,VarMap,OX), resolve_operand(Y,VarMap,OY),
    ( contains_unknown([OX,OY]) -> Viol=unsupported(fd_lt(X,Y))
    ; pairs_viol(OX,OY,[A,B]>>(A>=B),Viol) ).
viol_expr(fd_le(X,Y), VarMap, Viol) :- !,
    resolve_operand(X,VarMap,OX), resolve_operand(Y,VarMap,OY),
    ( contains_unknown([OX,OY]) -> Viol=unsupported(fd_le(X,Y))
    ; pairs_viol(OX,OY,[A,B]>>(A>B),Viol) ).
viol_expr(fdsumeq(X,K,Y), VarMap, Viol) :- !,
    resolve_operand(X,VarMap,OX), resolve_operand(K,VarMap,OK), resolve_operand(Y,VarMap,OY),
    ( contains_unknown([OX,OK,OY]) -> Viol=unsupported(fdsumeq(X,K,Y))
    ; sumeq_viol(OX,OK,OY,Viol) ).
viol_expr(fd_sum_eq(X,Y,Z), VarMap, Viol) :- !,
    resolve_operand(X,VarMap,OX), resolve_operand(Y,VarMap,OY), resolve_operand(Z,VarMap,OZ),
    ( contains_unknown([OX,OY,OZ]) -> Viol=unsupported(fd_sum_eq(X,Y,Z))
    ; sumeq_viol(OX,OY,OZ,Viol) ).
viol_expr(fdsumneq(X,K,Y), VarMap, Viol) :- !,
    resolve_operand(X,VarMap,OX), resolve_operand(K,VarMap,OK), resolve_operand(Y,VarMap,OY),
    ( contains_unknown([OX,OK,OY]) -> Viol=unsupported(fdsumneq(X,K,Y))
    ; sumeq_viol(OX,OK,OY,EV), complement_viol(EV,Viol) ).
viol_expr(fd_sum_neq(X,Y,Z), VarMap, Viol) :- !,
    resolve_operand(X,VarMap,OX), resolve_operand(Y,VarMap,OY), resolve_operand(Z,VarMap,OZ),
    ( contains_unknown([OX,OY,OZ]) -> Viol=unsupported(fd_sum_neq(X,Y,Z))
    ; sumeq_viol(OX,OY,OZ,EV), complement_viol(EV,Viol) ).
viol_expr(fd_product_eq(X,Y,Z), VarMap, Viol) :- !,
    resolve_operand(X,VarMap,OX), resolve_operand(Y,VarMap,OY), resolve_operand(Z,VarMap,OZ),
    ( contains_unknown([OX,OY,OZ]) -> Viol=unsupported(fd_product_eq(X,Y,Z))
    ; prodeq_viol(OX,OY,OZ,Viol) ).
viol_expr(fdalldifferent(L), VarMap, Viol) :- !,
    ( maplist({VarMap}/[Tm,Op]>>resolve_operand(Tm,VarMap,Op), L, Ops), contains_unknown(Ops) ->
        Viol = unsupported(fdalldifferent(L))
    ;   alldiff_viol(L,VarMap,Viol)
    ).
viol_expr(fd_all_different(L), VarMap, Viol) :- !, viol_expr(fdalldifferent(L), VarMap, Viol).
%% catch-all: moved to AFTER all specific clauses (see bottom of viol_expr section)
%% viol_expr(Goal, _, unsupported(Goal)).

%% ---------------------------------------------------------------------------
%% goal_terms(+Goals, +VarMap, +FixedAssoc, +PHard, -Terms)
%% ---------------------------------------------------------------------------
goal_terms(Goals, VarMap, FixedAssoc, PHard, Terms) :-
    findall(Ts,
        ( member(Goal, Goals), goal_contribution(Goal, VarMap, FixedAssoc, PHard, Ts) ),
        TermLists),
    flatten(TermLists, Terms).

goal_contribution(fd_domain(_,_,_), _, _, _, []) :- !.
goal_contribution(fd_domain(_,_), _, _, _, []) :- !.   %% sparse form: fd_domain(X, [v1,v2,...])
goal_contribution(fd_eq(X,Y), VarMap, FixedAssoc, PHard, Terms) :- !,
    ( clue_match(fd_eq(X,Y), FixedAssoc) ->
        %% Already encoded structurally via build_varmap/clue-fixing.
        Terms = []
    ;   resolve_operand(X,VarMap,OX), resolve_operand(Y,VarMap,OY),
        ( contains_unknown([OX,OY]) ->
            unsupported_error(fd_eq(X,Y), undeclared_identifier)
        ;   eq_viol(OX,OY,Viol),
            scale_viol(Viol, PHard, Scaled),
            viol_to_terms(Scaled, Terms)
        )
    ).
goal_contribution(fd_cost(W, C), VarMap, _FixedAssoc, _PHard, Terms) :- !,
    viol_expr(C, VarMap, Viol),
    ( Viol = unsupported(Why) ->
        unsupported_error(fd_cost(W, C), Why)
    ; W > 0 ->
        scale_viol(Viol, W, Scaled),
        viol_to_terms(Scaled, Terms)
    ; W < 0 ->
        %% contribution = W * (1 - Viol) = W - W*Viol
        scale_viol(Viol, -W, NegScaled),     % -W * Viol  (note -W > 0)
        viol_to_terms(NegScaled, NegTerms),
        Terms = [term(const,W) | NegTerms]
    ;   Terms = []
    ).
goal_contribution(Goal, VarMap, _FixedAssoc, PHard, Terms) :-
    is_hard_constraint(Goal), !,
    viol_expr(Goal, VarMap, Viol),
    ( Viol = unsupported(Why) ->
        unsupported_error(Goal, Why)
    ;   scale_viol(Viol, PHard, Scaled),
        viol_to_terms(Scaled, Terms)
    ).
goal_contribution(Goal, _, _, _, _) :-
    %% Anything else is not part of the language. (It used to be
    %% silently ignored -- e.g. fd_xor, fd_gt, fd_ge never reached the
    %% QUBO at all.)
    unsupported_error(Goal, not_a_recognised_constraint).

%% unsupported_error(+Goal, +Why): the QUBO cannot represent Goal. This
%% is an error rather than a warning: dropping a constraint silently
%% changes the problem, and the ground state then answers a different
%% question (previously these were skipped with a WARNING line).
unsupported_error(Goal, Why) :-
    format(string(Msg), "cannot encode ~q in the QUBO (~q)", [Goal, Why]),
    throw(error(domain_error(qubo_encodable_constraint, Goal), context(compile_qubo/3, Msg))).

% clue_match(+Goal, +FixedAssoc)
%   True if Goal is exactly the fd_eq/2 (in either argument order) that
%   caused a variable to be clue-fixed -- i.e. its Const matches the
%   value recorded in FixedAssoc for that Key.
clue_match(fd_eq(K,C), FixedAssoc) :-
    integer(C), get_assoc(K, FixedAssoc, V), V =:= C, !.
clue_match(fd_eq(C,K), FixedAssoc) :-
    integer(C), get_assoc(K, FixedAssoc, V), V =:= C, !.

is_hard_constraint(fd_neq(_,_)).
is_hard_constraint(fd_lt(_,_)).
is_hard_constraint(fd_le(_,_)).
is_hard_constraint(fdsumeq(_,_,_)).
is_hard_constraint(fdsumneq(_,_,_)).
is_hard_constraint(fd_sum_eq(_,_,_)).
is_hard_constraint(fd_sum_neq(_,_,_)).
is_hard_constraint(fd_product_eq(_,_,_)).
is_hard_constraint(fdalldifferent(_)).
is_hard_constraint(fd_all_different(_)).
is_hard_constraint(fd_weighted_sum(_,_)).
is_hard_constraint(fd_implies(_,_)).
is_hard_constraint(fd_or(_,_)).
is_hard_constraint(fd_count(_,_,_)).
is_hard_constraint(fd_atmost(_,_,_)).
is_hard_constraint(fd_atleast(_,_,_)).
is_hard_constraint(fd_abs_diff(_,_,_)).
is_hard_constraint(fd_min(_,_)).
is_hard_constraint(fd_max(_,_)).
is_hard_constraint(fd_gt(_,_)).
is_hard_constraint(fd_ge(_,_)).
is_hard_constraint(fd_xor(_,_,_)).
is_hard_constraint('$qclp_fn'(_,_,_,_)).

%% ---------------------------------------------------------------------------
%% viol_expr extensions for new constraint types
%% ---------------------------------------------------------------------------

%% fd_weighted_sum(+Pairs, +Target)
%%   Pairs = list of W*Var or W-Var (coefficient-variable pairs).
%%   Violation: sum(W_i * X_i) != Target.
%%
%%   Encoding: for each pair W*X, introduce a contribution variable C_i
%%   whose domain is {0, W, 2W, ..., domain_size*W}... actually since X
%%   is a domain variable in {Lo..Hi}, the contribution W*X ranges over
%%   {W*Lo, W*(Lo+1), ..., W*Hi}.  We encode directly via the one-hot
%%   indicator bits: the contribution of X=v to the weighted sum is W*v,
%%   which appears as coefficient W*v on bit b(X,v).
%%
%%   The violation indicator is:
%%     sum_over_valid_assignments [ product_i b(Xi,vi) * I(sum_i W_i*v_i != T) ]
%%   For 2+ variables this is generally cubic or higher -- we enumerate
%%   all combinations and use Phase 2 reduction where needed.
%%   For now, support the common case where at most one variable appears
%%   (pair-wise expansion via sumeq_viol chain is the user's job for N>2).
%%
%%   PRACTICAL ENCODING: treat as a special case.  For N=1:
%%     W*X = T  =>  X = T/W (if T divisible by W and T/W in domain)
%%   expressed as fd_eq(X, T/W).  For N=2: W1*X1 + W2*X2 = T.
%%   For general N: compile to a QUBO term by expanding:
%%     sum_i W_i * sum_v v * b(Xi,v) = T
%%   penalising via (sum_i W_i*Xi - T)^2 expressed quadratically.
%%   This requires pairs of bits products -- quadratic for N<=2, cubic for N>=3.
%%
%%   Current implementation: N<=2 via direct expansion; N>=3 reports
%%   unsupported (user should introduce intermediate sum variables).

viol_expr(fd_weighted_sum(Pairs, Target), VarMap, Viol) :- !,
    ( is_list(Pairs) -> true ; throw(error(type_error(list,Pairs),fd_weighted_sum/2)) ),
    maplist(parse_weight_pair(VarMap), Pairs, WOps),
    pairs_values(WOps, Ops),                          %% extract operands for unknown check
    ( contains_unknown(Ops) ->
        Viol = unsupported(fd_weighted_sum)
    ; length(WOps, N), T = Target ->
      ( N =:= 0 ->
          ( 0 =:= T -> Viol=viol(0,[],[]) ; Viol=viol(1,[],[]) )
      ; N =:= 1 ->
          WOps = [W-Op],
          ( Op = const(V) ->
              ( W*V =\= T -> Viol=viol(1,[],[]) ; Viol=viol(0,[],[]) )
          ;   findall(lin(Idx,1), ( domain_element(Op,V,Idx), W*V =\= T ), Lin),
              Viol=viol(0,Lin,[])
          )
      ; N =:= 2 ->
          WOps = [W1-Op1, W2-Op2],
          pairs_viol(Op1, Op2, [A,B]>>(W1*A + W2*B =\= T), Viol)
      ;   %% N >= 3: reduce to pairwise by introducing intermediate
          %% sum variable -- unsupported at compile time, user should
          %% use fdsumeq chain with intermediate domain variables.
          Viol = unsupported(fd_weighted_sum_n3_plus)
      )
    ).

%% fd_min / fd_max / fd_count / fd_atmost / fd_atleast are rewritten by
%% desugar_goals/2 into exact definitions over helper variables before
%% encoding (the previous direct encodings were approximate: fd_min only
%% enforced M =< every Xi, never that M equals one of them; fd_count
%% silently dropped its degree-4 parts when both Val and N were
%% variables; fd_atmost/fd_atleast were compiled as an exact count).

%% fd_abs_diff(+X, +Y, +D)  -- |X-Y| = D
%%   Rewritten to avoid multiply_viols (which can't handle cubic terms).
%%   |X-Y| = D  iff  (X-Y=D) OR (Y-X=D)
%%   Violation iff NOT((X=Y+D) OR (X+D=Y))
%%                = (X-Y != D) AND (Y-X != D)
%%   We directly enumerate valid (x,y,d) triples and mark violators.
%%   This produces a direct viol indicator without multiplication.
viol_expr(fd_abs_diff(X,Y,D), VarMap, Viol) :- !,
    resolve_operand(X, VarMap, OpX),
    resolve_operand(Y, VarMap, OpY),
    resolve_operand(D, VarMap, OpD),
    ( contains_unknown([OpX,OpY,OpD]) ->
        Viol = unsupported(fd_abs_diff)
    ;   %% Enumerate all (x,y,d) triples; penalise those where abs(x-y)!=d
        findall(T,
            ( domain_element(OpX,VX,IX),
              domain_element(OpY,VY,IY),
              domain_element(OpD,VD,ID),
              abs(VX-VY) =\= VD,
              classify_triple(IX,IY,ID,T)
            ),
            RawTerms),
        partition([Tm]>>(Tm=lin(_,_)), RawTerms, Lin, Rest),
        partition([Tm]>>(Tm=quad(_,_,_)), Rest, Quad, Cubic),
        Viol = viol(0, Lin, Quad, Cubic)
    ).

parse_weight_pair(VarMap, W*Var, W-Op) :- !,
    resolve_operand(Var, VarMap, Op).
parse_weight_pair(VarMap, W-Var, W-Op) :- !,
    resolve_operand(Var, VarMap, Op).
parse_weight_pair(_, P, _) :-
    throw(error(type_error(weight_pair,P), fd_weighted_sum/2)).

%% fd_implies(+C1, +C2)
%%   "If C1 is satisfied, then C2 must also be satisfied."
%%   Violation iff C1 is satisfied AND C2 is violated.
%%   violation_indicator = viol(C1_sat) * viol(C2_viol)
%%                       = (1 - viol_C1) * viol_C2
%%   where viol_X is the 0/1 violation indicator of X.
%%   Expanding: viol_C2 - viol_C1*viol_C2.
%%   The product viol_C1*viol_C2 is a product of two quadratic
%%   polynomials -> up to degree 4. For the common case where both
%%   viols are linear (binary variables), this stays quadratic.
%%   We implement via: complement_viol(C1_viol, C1_sat), then
%%   pair the product terms.
viol_expr(fd_implies(C1,C2), VarMap, Viol) :- !,
    viol_expr(C1, VarMap, Viol1),
    viol_expr(C2, VarMap, Viol2),
    ( Viol1 = unsupported(_) -> Viol = Viol1
    ; Viol2 = unsupported(_) -> Viol = Viol2
    ;   %% C1_satisfied = 1 - viol(C1)
        %% Viol = viol(C1_satisfied AND C2_violated)
        %% = viol(C1_satisfied) * Viol2
        complement_viol(Viol1, C1_sat),
        multiply_viols(C1_sat, Viol2, Viol)
    ).

%% fd_or(+C1, +C2)
%%   "At least one of C1, C2 must be satisfied."
%%   Violation iff both are violated.
%%   violation_indicator = viol(C1) * viol(C2)
viol_expr(fd_or(C1,C2), VarMap, Viol) :- !,
    viol_expr(C1, VarMap, Viol1),
    viol_expr(C2, VarMap, Viol2),
    ( Viol1 = unsupported(_) -> Viol = Viol1
    ; Viol2 = unsupported(_) -> Viol = Viol2
    ;   multiply_viols(Viol1, Viol2, Viol)
    ).

%% multiply_viols(+V1, +V2, -Prod)
%%   Product of two violation polynomials over binary variables
%%   (b*b = b). Either factor may be in the 3- or 4-field form (eq_viol
%%   and friends build viol/3; complement_viol builds viol/4). Until
%%   2 Oct 2026 only viol/4 heads were matched, so fd_or and fd_implies
%%   always came out "unsupported", even the Language Reference's own
%%   example. Supported: a constant times anything; two polynomials of
%%   degree <= 1 (product of degree 2); degree 1 times degree 2 (product
%%   of degree 3: cubic terms, Rosenberg-reduced as elsewhere). Higher
%%   degrees are unsupported.
multiply_viols(unsupported(W), _, unsupported(W)) :- !.
multiply_viols(_, unsupported(W), unsupported(W)) :- !.
multiply_viols(V1, V2, Viol) :-
    to_viol4(V1, viol(C1,L1,Q1,Cu1)),
    to_viol4(V2, viol(C2,L2,Q2,Cu2)),
    (   L1 == [], Q1 == [], Cu1 == []
    ->  scale_viol(viol(C2,L2,Q2,Cu2), C1, Viol)
    ;   L2 == [], Q2 == [], Cu2 == []
    ->  scale_viol(viol(C1,L1,Q1,Cu1), C2, Viol)
    ;   Cu1 == [], Cu2 == [], ( Q1 == [] ; Q2 == [] )
    ->  C is C1*C2,
        scale_viol(viol(0,L2,Q2,[]), C1, viol(_,LA,QA,_)),
        scale_viol(viol(0,L1,Q1,[]), C2, viol(_,LB,QB,_)),
        findall(T, ( member(X, L1), member(Y, L2), mono_product(X, Y, T) ), T1),
        findall(T, ( member(X, L1), member(Y, Q2), mono_product(X, Y, T) ), T2),
        findall(T, ( member(X, Q1), member(Y, L2), mono_product(Y, X, T) ), T3),
        append([T1, T2, T3], Ts),
        include([T]>>(T = lin(_,_)), Ts, LP),
        include([T]>>(T = quad(_,_,_)), Ts, QP),
        include([T]>>(T = cubic(_,_,_,_)), Ts, CP),
        append([LA, LB, LP], L), append([QA, QB, QP], Q),
        Viol = viol(C, L, Q, CP)
    ;   Viol = unsupported(multiply(V1,V2))
    ).

%% mono_product(+Lin, +LinOrQuad, -Term): product of two monomials, b*b = b
mono_product(lin(I,A), lin(J,B), T) :- !,
    K is A*B,
    ( I =:= J -> T = lin(I,K) ; I < J -> T = quad(I,J,K) ; T = quad(J,I,K) ).
mono_product(lin(I,A), quad(J,K0,B), T) :-
    K is A*B,
    (   ( I =:= J ; I =:= K0 ) -> T = quad(J,K0,K)
    ;   msort([I,J,K0], [P,Q,R]), T = cubic(P,Q,R,K)
    ).

resolve_op(VarMap, X, Op) :- resolve_operand(X, VarMap, Op).

%% fd_gt / fd_ge: mirror fd_lt / fd_le.
viol_expr(fd_gt(X,Y), VarMap, Viol) :- !, viol_expr(fd_lt(Y,X), VarMap, Viol).
viol_expr(fd_ge(X,Y), VarMap, Viol) :- !, viol_expr(fd_le(Y,X), VarMap, Viol).

%% fd_xor(X, Y, Z): Z = X xor Y (bitwise). At most three one-hot
%% blocks, so the violation indicator is exact (cubic terms are
%% Rosenberg-reduced as usual).
viol_expr(fd_xor(X,Y,Z), VarMap, Viol) :- !,
    maplist(resolve_op(VarMap), [X,Y,Z], Ops),
    ( contains_unknown(Ops) -> Viol = unsupported(fd_xor(X,Y,Z))
    ; enum_viol(Ops, [[A,B,C]]>>(C =\= A xor B), Viol) ).

%% '$qclp_fn'(F, X, Y, Z): Z = F(X, Y) -- internal helper relation made
%% by desugar_goals/2. F is min, max, eqind (1 if X = Y else 0), or
%% wsum(WX, WY) (WX*X + WY*Y).
viol_expr('$qclp_fn'(F,X,Y,Z), VarMap, Viol) :- !,
    maplist(resolve_op(VarMap), [X,Y,Z], Ops),
    ( contains_unknown(Ops) -> Viol = unsupported('$qclp_fn'(F,X,Y,Z))
    ; enum_viol(Ops, [[A,B,C]]>>(qclp_fn_value(F, A, B, V), C =\= V), Viol) ).

qclp_fn_value(min, A, B, V)          :- V is min(A, B).
qclp_fn_value(max, A, B, V)          :- V is max(A, B).
qclp_fn_value(eqind, A, B, V)        :- ( A =:= B -> V = 1 ; V = 0 ).
qclp_fn_value(wsum(WA, WB), A, B, V) :- V is WA*A + WB*B.

%% enum_viol(+Ops, +Pred, -Viol)
%%   Exact violation indicator for a relation over up to three one-hot
%%   blocks (operands may also be constants, or the same variable more
%%   than once). For every assignment of the DISTINCT variables that
%%   makes call(Pred, Values) true, add the product of their one-hot
%%   bits; valid one-hot assignments therefore score exactly 0 or 1.
enum_viol(Ops, Pred, Viol) :-
    distinct_var_ops(Ops, [], DVs),
    length(DVs, NV),
    (   NV > 3
    ->  Viol = unsupported(more_than_three_variables)
    ;   findall(T,
            ( assign_vars(DVs, Asg),
              maplist(op_value_in(Asg), Ops, Vals),
              call(Pred, Vals),
              pairs_values(Asg, IdxVals), maplist([_-I, I]>>true, IdxVals, Idxs),
              monomial(Idxs, T) ),
            Terms),
        partition([Tm]>>(Tm = konst(_)), Terms, Ks, Rest0),
        length(Ks, NK),
        partition([Tm]>>(Tm = lin(_,_)), Rest0, Lin, Rest1),
        partition([Tm]>>(Tm = quad(_,_,_)), Rest1, Quad, Cubic),
        Viol = viol(NK, Lin, Quad, Cubic)
    ).

distinct_var_ops([], Acc, DVs) :- reverse(Acc, DVs).
distinct_var_ops([Op|Ops], Acc, DVs) :-
    (   is_domain_var(Op), Op = var(K,_,_),
        \+ ( member(var(K2,_,_), Acc), K2 == K )
    ->  distinct_var_ops(Ops, [Op|Acc], DVs)
    ;   distinct_var_ops(Ops, Acc, DVs)
    ).

%% assign_vars(+DistinctVarOps, -Assignment): Key-(Value-BitIdx) per var
assign_vars([], []).
assign_vars([Op|Ops], [K-(V-I)|Rest]) :-
    Op = var(K,_,_), domain_element(Op, V, I), assign_vars(Ops, Rest).

op_value_in(_, const(V), V) :- !.
op_value_in(Asg, var(K,_,_), V) :- member(K2-(V-_), Asg), K2 == K, !.

monomial([], konst(1)).
monomial([I], lin(I,1)) :- !.
monomial([I,J], quad(A,B,1)) :- !, msort([I,J], [A,B]).
monomial([I,J,K], cubic(A,B,C,1)) :- msort([I,J,K], [A,B,C]).

%% Catch-all: any unrecognised constraint term is unsupported.
%% MUST be the last viol_expr clause.
viol_expr(Goal, _, unsupported(Goal)).

%% merge_terms(+Terms, -Const, -Lin, -Quad)
%%   Sums duplicate term(const,_), term(lin,I,_), term(quad,I,J,_) entries.
%%   Lin  = list of I-Coeff   (Coeff \== 0)
%%   Quad = list of (I-J)-Coeff  (I<J, Coeff \== 0)
%% ---------------------------------------------------------------------------
merge_terms(Terms, Const, Lin, Quad) :-
    partition_terms(Terms, Consts, LinTs, QuadTs),
    sum_list(Consts, Const),
    findall(I-C, member(term(lin,I,C),LinTs), LinPairsRaw),
    group_sum(LinPairsRaw, Lin0),
    exclude([_-C]>>(C =:= 0), Lin0, Lin),
    findall((I-J)-C, member(term(quad,I,J,C),QuadTs), QuadPairsRaw),
    group_sum(QuadPairsRaw, Quad0),
    exclude([_-C]>>(C =:= 0), Quad0, Quad).

partition_terms([], [], [], []).
partition_terms([term(const,C)|T], [C|Cs], Ls, Qs) :- !, partition_terms(T,Cs,Ls,Qs).
partition_terms([T0|T], Cs, [T0|Ls], Qs) :- T0 = term(lin,_,_), !, partition_terms(T,Cs,Ls,Qs).
partition_terms([T0|T], Cs, Ls, [T0|Qs]) :- T0 = term(quad,_,_,_), !, partition_terms(T,Cs,Ls,Qs).
partition_terms([_|T], Cs, Ls, Qs) :- partition_terms(T,Cs,Ls,Qs).

% group_sum(+Pairs, -SummedPairs)
%   Pairs is a list of Key-Number. SummedPairs has one Key-Sum entry per
%   distinct Key (Keys compared with =, suitable for integers and I-J
%   integer pairs).
group_sum(Pairs, SummedPairs) :-
    keysort(Pairs, Sorted),
    group_sum_(Sorted, SummedPairs).

group_sum_([], []).
group_sum_([K-V|Rest], [K-Sum|Out]) :-
    take_same_key(K, Rest, Vs, Rest1),
    sum_list([V|Vs], Sum),
    group_sum_(Rest1, Out).

take_same_key(K, [K-V|Rest], [V|Vs], Rest1) :- !, take_same_key(K,Rest,Vs,Rest1).
take_same_key(_, Rest, [], Rest).

%% ---------------------------------------------------------------------------
%% name_var_table(+VarTable0, +VarNames, -VarTable)
%%   Replaces each Key with its display name: the source atom (e.g. v0, w1)
%%   if Key is an atom, or the source variable name (e.g. 'Q0') recovered
%%   via VarNames if Key is a genuine Prolog variable.
%% ---------------------------------------------------------------------------
name_var_table([], _, []).
name_var_table([bitvar(Idx,Key,Val)|T], VarNames, [bitvar(Idx,Name,Val)|RT]) :-
    display_name(Key, VarNames, Name),
    name_var_table(T, VarNames, RT).
name_var_table([fixedvar(Key,Val)|T], VarNames, [fixedvar(Name,Val)|RT]) :-
    display_name(Key, VarNames, Name),
    name_var_table(T, VarNames, RT).
name_var_table([auxvar(Idx,Label)|T], VarNames, [auxvar(Idx,Label)|RT]) :- !,
    name_var_table(T, VarNames, RT).

display_name(Key, VarNames, Name) :-
    ( var(Key), find_var_name(Key, VarNames, Found) -> Name = Found ; Name = Key ).

find_var_name(Key, [N=V|_], N) :- V == Key, !.
find_var_name(Key, [_|T], N) :- find_var_name(Key, T, N).

%% ---------------------------------------------------------------------------
%% qubo_energy(+qubo(Const,Lin,Quad), +BitList, -Energy)
%%   BitList is a list of 0/1 values, BitList[I] = value of binary var I
%%   (0-indexed).
%% ---------------------------------------------------------------------------
qubo_energy(qubo(Const,Lin,Quad), BitList, Energy) :-
    foldl(lin_contrib(BitList), Lin, 0, LinSum),
    foldl(quad_contrib(BitList), Quad, 0, QuadSum),
    Energy is Const + LinSum + QuadSum.

lin_contrib(BitList, I-C, Acc, Acc2) :-
    nth0(I, BitList, Xi), Acc2 is Acc + C*Xi.
quad_contrib(BitList, (I-J)-C, Acc, Acc2) :-
    nth0(I, BitList, Xi), nth0(J, BitList, Xj), Acc2 is Acc + C*Xi*Xj.

%% ---------------------------------------------------------------------------
%% qubo_decode(+VarTable, +BitList, -Assignment)
%%   Assignment is a list of Name=Value pairs: one per fixedvar entry
%%   (always included), plus one per bitvar entry whose bit is 1.
%% ---------------------------------------------------------------------------
qubo_decode(VarTable, BitList, Assignment) :-
    findall(Name=Val,
        ( member(fixedvar(Name,Val), VarTable)
        ; member(bitvar(Idx,Name,Val), VarTable), nth0(Idx,BitList,1)
        ),
        Assignment).

%% ---------------------------------------------------------------------------
%% qubo_valid(+VarTable, +BitList)
%%   True iff every one-hot block in VarTable has exactly one bit set in
%%   BitList. Useful to check whether an annealer result is a "legal"
%%   encoding (vs. an infeasible/garbage bitstring).
%% ---------------------------------------------------------------------------
qubo_valid(VarTable, BitList) :-
    findall(Key, member(bitvar(_,Key,_), VarTable), KeysDup),
    sort(KeysDup, Keys),
    forall(member(Key,Keys),
        ( findall(1, ( member(bitvar(Idx,Key,_),VarTable), nth0(Idx,BitList,1) ), Ones),
          length(Ones,1)
        )).

%% ---------------------------------------------------------------------------
%% qubo_blocks(+VarTable, -Blocks)
%%   Blocks is a list of lists of binary-variable indices, one list per
%%   one-hot encoded qclp variable (fixed/clue variables contribute no
%%   block). Used by qclp_qubo_sa for "block-swap" moves that reassign a
%%   variable's value in one step without passing through an invalid
%%   intermediate state.
%% ---------------------------------------------------------------------------
qubo_blocks(VarTable, Blocks) :-
    findall(Key, member(bitvar(_,Key,_), VarTable), KeysDup),
    list_to_set(KeysDup, Keys),
    findall(Idxs,
        ( member(Key,Keys),
          findall(Idx, member(bitvar(Idx,Key,_),VarTable), Idxs)
        ),
        Blocks).

%% ---------------------------------------------------------------------------
%% qubo_write(+Result, +FilePath, +SourceName)
%%   Writes a simple, generic QUBO file: a variable table (binary index ->
%%   qclp variable/value it represents), the constant offset, and the
%%   linear and quadratic coefficients. Also writes a Python dict literal
%%   suitable for dimod.BinaryQuadraticModel(linear, quadratic, offset, 'BINARY').
%% ---------------------------------------------------------------------------
qubo_write(qubo(Const,Lin,Quad)-VarTable-NBits, FilePath, SourceName) :-
    setup_call_cleanup(
        open(FilePath, write, Stream),
        write_qubo(Stream, Const, Lin, Quad, VarTable, NBits, SourceName),
        close(Stream)
    ).

write_qubo(S, Const, Lin, Quad, VarTable, NBits, SourceName) :-
    format(S, "% QUBO generated by qclp_qubo from ~w~n", [SourceName]),
    format(S, "% ~w binary variables~n", [NBits]),
    format(S, "%~n% Variable table: index -> (qclp key = value)~n", []),
    forall(member(bitvar(Idx,Key,Val), VarTable),
           format(S, "%   ~w : ~w = ~w~n", [Idx,Key,Val])),
    forall(member(fixedvar(Key,Val), VarTable),
           format(S, "%   (fixed) ~w = ~w~n", [Key,Val])),
    forall(member(auxvar(Idx,pair(I,J)), VarTable),
           format(S, "%   ~w : (aux, Phase 2) = b~w * b~w~n", [Idx,I,J])),
    format(S, "~nconstant ~w~n", [Const]),
    forall(member(I-C, Lin), format(S, "linear ~w ~w~n", [I,C])),
    forall(member((I-J)-C, Quad), format(S, "quadratic ~w ~w ~w~n", [I,J,C])),
    %% Python / dimod-style dict export
    format(S, "~n% --- Python (dimod) ---~n", []),
    format(S, "% linear = {~n", []),
    forall(member(I-C, Lin), format(S, "%   ~w: ~w,~n", [I,C])),
    format(S, "% }~n", []),
    format(S, "% quadratic = {~n", []),
    forall(member((I-J)-C, Quad), format(S, "%   (~w, ~w): ~w,~n", [I,J,C])),
    format(S, "% }~n", []),
    format(S, "% offset = ~w~n", [Const]),
    format(S, "% bqm = dimod.BinaryQuadraticModel(linear, quadratic, offset, dimod.BINARY)~n", []).
