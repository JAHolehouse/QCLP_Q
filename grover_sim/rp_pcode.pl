%% =============================================================================
%%  rp_pcode.pl  --  Pcode interpreter for Grover oracle evaluation
%%
%%  pcode_eval(+pcode(Spec, DomainMap), +FreeAssign)
%%    FreeAssign contains Var-Value pairs for the free (non-clue) variables.
%%    Clue-fixed values (fd_eq(Var, Const)) are merged in before checking.
%%    Succeeds iff the assignment satisfies all hard constraints in Spec.
%% =============================================================================

:- module(rp_pcode, [pcode_eval/2]).

:- use_module(library(lists)).

pcode_eval(pcode(Spec, _DomainMap), FreeAssign) :-
    findall(V-C, (member(fd_eq(V,C), Spec), atom(V), number(C)), Clues),
    append(Clues, FreeAssign, Assign),
    exclude(is_skip(Clues), Spec, Constraints),
    maplist(eval_constraint(Assign), Constraints).

is_skip(_, fd_domain(_, _))    :- !.
is_skip(_, fd_domain(_, _, _)) :- !.
is_skip(_, fd_cost(_, _))      :- !.
is_skip(Clues, fd_eq(V, C))    :- atom(V), number(C), member(V-C, Clues), !.
is_skip(_, _) :- fail.

%% Every constraint is checked by rp_fd:holds/2, the single definition
%% of the vocabulary shared with gsim's classical enumerator.
eval_constraint(A, C) :- rp_fd:holds(C, A).
