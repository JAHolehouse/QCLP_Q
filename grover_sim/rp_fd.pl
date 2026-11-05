%% =============================================================================
%%  rp_fd.pl  --  FD spec interpreter for Grover simulation
%%
%%  Mirrors the domain and constraint handling of clpfd_evaluator.pl
%%  but uses plain Prolog arithmetic instead of CLP(FD), so it can
%%  coexist with and is not affected by the clpfd module.
%%
%%  Domain syntax supported (matching the evaluator):
%%    fd_domain(Var, Lo, Hi)          integer range Lo..Hi
%%    fd_domain(Var, [e1, e2, ...])   explicit list where each element is:
%%                                      integer N       singleton value N
%%                                      Lo-Hi           inclusive range Lo..Hi
%%
%%  Constraint vocabulary supported:
%%    fd_eq, fd_neq, fd_lt, fd_le, fd_gt, fd_ge
%%    fdsumeq, fd_sum_eq
%%    fd_product_eq
%%    fdalldifferent, fd_all_different
%%    fd_weighted_sum, fd_abs_diff, fd_min, fd_max, fd_count
%%    fd_cost (soft -- skipped in oracle; ignored in hard-constraint check)
%%    fd_eq(Var, Const) with atom Var -- clue fix (excluded from enumeration)
%% =============================================================================

:- module(rp_fd, [
    rp_fd_solve/2,
    fd_spec_domains/2,
    fd_domain_size/2,
    rp_fd_oracle_mc/2,
    holds/2
]).

:- use_module(library(lists)).

%% ---------------------------------------------------------------------------
%%  Domain normalisation helpers (mirrors clpfd_evaluator.pl)
%% ---------------------------------------------------------------------------

%% expand_domain_elem(+Elem, -Values)
%%   Converts one element of a list domain to a flat list of integers.
expand_domain_elem(Lo-Hi, Vals) :-
    integer(Lo), integer(Hi), !,
    numlist(Lo, Hi, Vals).
expand_domain_elem(N, [N]) :-
    integer(N), !.

%% expand_domain_list(+List, -Values)
%%   Expands a full list domain (possibly containing Lo-Hi ranges) to
%%   a flat sorted list of unique integer values.
expand_domain_list(List, Values) :-
    maplist(expand_domain_elem, List, NestedVals),
    append(NestedVals, AllVals),
    sort(AllVals, Values).

%% ---------------------------------------------------------------------------
%%  fd_spec_domains(+Spec, -Domains)
%%
%%  Returns dom(Var, Lo, Hi) for every fd_domain declaration, using the
%%  actual min/max of the expanded value list as Lo/Hi.
%%  Clue-fixed variables (fd_eq(Var, Const)) are excluded.
%% ---------------------------------------------------------------------------

fd_spec_domains(Spec, Domains) :-
    include(is_fd_domain, Spec, DomGoals),
    maplist(goal_to_dom, DomGoals, AllDoms),
    findall(V, (member(fd_eq(V,C), Spec), atom(V), number(C)), Fixed),
    exclude([dom(V,_,_)]>>(member(V, Fixed)), AllDoms, Domains).

is_fd_domain(fd_domain(_, _))    :- !.
is_fd_domain(fd_domain(_, _, _)) :- !.
is_fd_domain(_) :- fail.

goal_to_dom(fd_domain(Var, List), dom(Var, Lo, Hi)) :-
    is_list(List), !,
    expand_domain_list(List, Values),
    min_list(Values, Lo),
    max_list(Values, Hi).
goal_to_dom(fd_domain(Var, Lo, Hi), dom(Var, Lo, Hi)) :- !.

%% fd_domain_size(+Domain, -Size)
fd_domain_size(dom(_, Lo, Hi), Size) :- Size is Hi - Lo + 1.

%% ---------------------------------------------------------------------------
%%  rp_fd_solve(+Spec, -Solutions)
%%
%%  Enumerate all satisfying assignments by classical backtracking.
%%  Clue-fixed variables are pre-bound and not enumerated.
%% ---------------------------------------------------------------------------

rp_fd_solve(Spec, Solutions) :-
    fd_spec_domains(Spec, Domains),
    findall(V-C, (member(fd_eq(V,C), Spec), atom(V), number(C)), Clues),
    exclude(is_fd_domain_or_clue(Clues), Spec, Constraints),
    findall(Assign,
        ( enumerate_domains(Domains, Spec, FreeAssign),
          append(Clues, FreeAssign, Assign),
          check_constraints(Constraints, Assign)
        ),
        Solutions).

is_fd_domain_or_clue(_, fd_domain(_, _))   :- !.
is_fd_domain_or_clue(_, fd_domain(_, _, _)):- !.
is_fd_domain_or_clue(Clues, fd_eq(V, C)) :-
    atom(V), number(C), member(V-C, Clues), !.
is_fd_domain_or_clue(_, _) :- fail.

%% enumerate_domains: for each free variable, enumerate its actual values
enumerate_domains([], _, []).
enumerate_domains([dom(Var, Lo, Hi)|Rest], Spec, [Var-Val|Assigns]) :-
    actual_values(Var, Spec, Lo, Hi, Values),
    member(Val, Values),
    enumerate_domains(Rest, Spec, Assigns).

actual_values(Var, Spec, _Lo, _Hi, Values) :-
    member(fd_domain(Var, List), Spec), is_list(List), !,
    expand_domain_list(List, Values).
actual_values(_, _, Lo, Hi, Values) :-
    numlist(Lo, Hi, Values).

%% ---------------------------------------------------------------------------
%%  Constraint checking (plain arithmetic, no CLP(FD))
%% ---------------------------------------------------------------------------

check_constraints([], _).
check_constraints([C|Cs], Assign) :-
    ( check_one(C, Assign) -> true ; fail ),
    check_constraints(Cs, Assign).

check_one(fd_domain(_, _), _)    :- !.
check_one(fd_domain(_, _, _), _) :- !.
check_one(fd_cost(_, _), _)      :- !.           %% soft -- always passes hard check
check_one(fd_eq(V, C), _) :- atom(V), number(C), !. %% clue -- already bound
check_one(C, A) :- holds(C, A).

%% holds(+Constraint, +Assignment)
%%   True iff Constraint is satisfied by Assignment (a Var-Value list).
%%   The single definition of the constraint vocabulary for gsim (the
%%   classical enumerator here and the Grover oracle in rp_pcode.pl both
%%   use it). Mirrors clp_evaluator/clpfd_evaluator.pl's con_expr/3.
%%   An unrecognised constraint is an ERROR (it used to make every
%%   assignment fail, so gsim reported 0 solutions).
holds(fd_eq(X, Y), A)            :- !, rv(X,A,VX), rv(Y,A,VY), VX =:= VY.
holds(fd_neq(X, Y), A)           :- !, rv(X,A,VX), rv(Y,A,VY), VX =\= VY.
holds(fd_lt(X, Y), A)            :- !, rv(X,A,VX), rv(Y,A,VY), VX < VY.
holds(fd_le(X, Y), A)            :- !, rv(X,A,VX), rv(Y,A,VY), VX =< VY.
holds(fd_gt(X, Y), A)            :- !, rv(X,A,VX), rv(Y,A,VY), VX > VY.
holds(fd_ge(X, Y), A)            :- !, rv(X,A,VX), rv(Y,A,VY), VX >= VY.
holds(fdsumeq(X, Y, Z), A)       :- !, rv(X,A,VX), rv(Y,A,VY), rv(Z,A,VZ), VX+VY =:= VZ.
holds(fd_sum_eq(X, Y, Z), A)     :- !, holds(fdsumeq(X,Y,Z), A).
holds(fdsumneq(X, K, Y), A)      :- !, rv(X,A,VX), rv(K,A,VK), rv(Y,A,VY), VX+VK =\= VY.
holds(fd_sum_neq(X, K, Y), A)    :- !, holds(fdsumneq(X,K,Y), A).
holds(fd_product_eq(X, Y, Z), A) :- !, rv(X,A,VX), rv(Y,A,VY), rv(Z,A,VZ), VX*VY =:= VZ.
holds(fdalldifferent(L), A)      :- !, maplist(rv_l(A), L, Vs), all_diff(Vs).
holds(fd_all_different(L), A)    :- !, holds(fdalldifferent(L), A).
holds(fd_weighted_sum(Ts, T), A) :- !, maplist(weighted_term(A), Ts, Vs), rv(T,A,VT),
                                    sum_list(Vs, S), S =:= VT.
holds(fd_abs_diff(X, Y, D), A)   :- !, rv(X,A,VX), rv(Y,A,VY), rv(D,A,VD), VD =:= abs(VX-VY).
holds(fd_min(List, M), A)        :- !, maplist(rv_l(A), List, Vs), rv(M,A,VM),
                                    min_list(Vs, Min), VM =:= Min.
holds(fd_max(List, M), A)        :- !, maplist(rv_l(A), List, Vs), rv(M,A,VM),
                                    max_list(Vs, Max), VM =:= Max.
holds(fd_count(L, Val, N), A)    :- !, count_eq(L, Val, A, C), rv(N,A,VN), C =:= VN.
holds(fd_atmost(N, L, Val), A)   :- !, count_eq(L, Val, A, C), rv(N,A,VN), C =< VN.
holds(fd_atleast(N, L, Val), A)  :- !, count_eq(L, Val, A, C), rv(N,A,VN), C >= VN.
holds(fd_xor(X, Y, Z), A)        :- !, rv(X,A,VX), rv(Y,A,VY), rv(Z,A,VZ), VZ =:= VX xor VY.
holds(fd_implies(C1, C2), A)     :- !, ( holds(C1, A) -> holds(C2, A) ; true ).
holds(fd_or(C1, C2), A)          :- !, ( holds(C1, A) -> true ; holds(C2, A) ).
holds(C, _) :-
    format(string(Msg), "~q is not a recognised constraint (see docs/Language_Reference.md)", [C]),
    throw(error(domain_error(qclp_constraint, C), context(gsim/2, Msg))).

count_eq(L, Val, A, Count) :-
    maplist(rv_l(A), L, Vs), rv(Val, A, VV),
    include([V]>>(V =:= VV), Vs, Matches), length(Matches, Count).

%% weighted_term(+A, +Term, -Value): W*X (or W-X) with integer W.
%% (Previously each term was passed to arithmetic unresolved, so
%% fd_weighted_sum raised type_error(evaluable, x/0).)
weighted_term(A, W*X, V) :- integer(W), !, rv(X, A, VX), V is W*VX.
weighted_term(A, W-X, V) :- integer(W), !, rv(X, A, VX), V is W*VX.
weighted_term(A, X, V) :- rv(X, A, V).

rv(X, _, X)   :- number(X), !.
rv(X, A, V)   :- atom(X), memberchk(X-V, A), !.
rv(X, _, _)   :-
    format(string(Msg), "~q is used in a constraint but has no fd_domain declaration", [X]),
    throw(error(existence_error(fd_variable, X), context(gsim/2, Msg))).

rv_l(A, X, V) :- rv(X, A, V).

all_diff([]).
all_diff([X|Xs]) :- \+ member(X, Xs), all_diff(Xs).

%% ---------------------------------------------------------------------------
%%  rp_fd_oracle_mc(+Spec, -OracleMC)
%%
%%  Returns pcode(Spec, DomainMap) where DomainMap maps each free
%%  variable to its actual expanded value list (for index decoding).
%% ---------------------------------------------------------------------------

rp_fd_oracle_mc(Spec, pcode(Spec, DomainMap)) :-
    fd_spec_domains(Spec, Domains),
    maplist(dom_to_value_list(Spec), Domains, DomainMap).

dom_to_value_list(Spec, dom(Var, Lo, Hi), Var-Values) :-
    ( member(fd_domain(Var, List), Spec), is_list(List) ->
        expand_domain_list(List, Values)
    ;   numlist(Lo, Hi, Values)
    ).
