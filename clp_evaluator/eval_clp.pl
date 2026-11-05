:- module(eval_clp, [eval/1]).
:- use_module(clpfd_evaluator, [eval/3]).

%% eval(+File): classical CLP(FD) optimum of a .clp file.
%% Deterministic: the first (optimal) answer is reported once, rather
%% than leaving a choice point at the top level.
eval(FileName) :-
    format('~n--- [clpfd] Optimization Engine for [~w] ---~n', [FileName]),
    once(eval(FileName, Assignment, Cost)),
    format('Optimal Assignment Found: ~w~n', [Assignment]),
    format('Minimized Total Penalty: ~w~n', [Cost]).
