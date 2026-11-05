%% ============================================================
%%  qsim_pp_grover.pl  --  Grover FD search simulator
%%
%%  Classically simulates the output distribution of a Grover
%%  search by running the oracle/diffuse iteration directly on
%%  the oracle pcode (rp_fd_oracle_mc/2) over the FD search space.
%%
%%  The pcode is the simulation input.  Compiled QASM (rp_grover_qasm/2)
%%  is a separate, parallel output for hardware targets -- it is not
%%  read back for simulation.
%%
%%  Usage:
%%    rp_fd_compile(Goals, FDSpec),
%%    qsim_pp_grover:run_fdspec(FDSpec, Results).
%%
%%  Results = grover_result(Solutions, FinalState)
%%
%%  After running, use grover_decode/2 and grover_top/1 to inspect
%%  the resulting amplitude distribution.
%%
%%  CHANGE LOG:
%%    v1: extracted from qsim_macro.pl monolith
%%    v2: oracle evaluation moved to rp_pcode (pcode interpreter)
%%    v3: run_fdspec/2 added -- pcode-direct entry point,
%%        no QASM file involved; qsim_macro.pl removed
%% ============================================================

:- module(qsim_pp_grover, [
    run_fdspec/2,        %% run_fdspec(+Spec, -Results): Grover search, unknown M
    run_fdspec/3,        %% run_fdspec(+Spec, +Opts, -Results): seed(S), budget(B)
    grover_decode/2,     %% grover_decode(+StateIdx, -Assignment)
    grover_top/1         %% grover_top(+N) -- show top N states from last sim
]).

:- use_module(library(lists)).
:- use_module(library(random)).
:- use_module(library(assoc)).
:- use_module(library(apply)).
:- use_module(rp_fd,      [
                            fd_domain_size/2, fd_spec_domains/2,
                            rp_fd_oracle_mc/2]).
:- use_module(rp_pcode,   [pcode_eval/2]).
:- use_module(rp_grover,  [rp_grover_iterations_m/3]).


%% ============================================================
%% ============================================================
%%  Pcode-direct entry point (no QASM file involved)
%% ============================================================

%%  run_fdspec(+FDSpec, -Results)
%%
%%  Computes K from the FDSpec (rp_grover_iterations*), compiles
%%  the oracle pcode, runs the Grover amplitude iteration, and
%%  stores results for grover_decode/2 and grover_top/1.
%%
%%  Results = grover_result(Solutions, FinalState)
%% Maximum search space size for gsim (above this, classical enumeration
%% in rp_fd_solve and Grover state vector both become impractical)
gsim_max_n(100000).

run_fdspec(FDSpec, Result) :- run_fdspec(FDSpec, [], Result).

run_fdspec(FDSpec, Opts, grover_result(Solutions, FinalState)) :-
    rp_fd_oracle_mc(FDSpec, OracleMC),
    OracleMC = pcode(_, DomMap),
    maplist(dommap_size, DomMap, DomSizes),
    product_list(DomSizes, 1, N),

    %% Guard: abort if search space is too large
    gsim_max_n(MaxN),
    ( N > MaxN ->
        format("[gsim] ERROR: Search space N=~w exceeds gsim limit of ~w.~n", [N, MaxN]),
        format("[gsim]   Use eval/1 for classical solution, or qsim/2 for QAOA.~n"),
        format("[gsim]   Tip: reduce domain sizes or add more hard constraints.~n"),
        fail
    ; true ),

    %% No classical solve: the number of solutions is unknown. The
    %% oracle evaluates the constraints on each basis state (pcode_eval/2
    %% calls holds/2), which is what the quantum oracle does in
    %% superposition; the search uses those verdicts only as phase flips
    %% and to check a measured candidate. (Before 1 Oct 2026 gsim solved
    %% the problem classically first and chose K from the number of
    %% solutions.)
    ( memberchk(seed(Seed), Opts) -> set_random(seed(Seed)) ; true ),
    ( memberchk(budget(B), Opts) -> true ; B = 9 ),
    N1 is N - 1,
    findall(F, ( between(0, N1, I),
                 ( eval_fd_oracle(OracleMC, DomMap, I) -> F = -1.0 ; F = 1.0 ) ), Flips),
    Budget is ceiling(B * sqrt(float(N))),
    format("[gsim] search space N=~w; number of solutions unknown~n", [N]),
    format("[gsim] exponential search (unknown M), budget ~w oracle calls~n", [Budget]),
    Amp is 1.0 / sqrt(float(N)),
    length(V0, N), maplist(=(Amp), V0),
    SqrtN is sqrt(float(N)),
    bbht_round(1.0, SqrtN, N, Flips, V0, Budget, 1, 0, R, FinalVec, K),
    (   R = found(Idx, Calls)
    ->  decode_index(Idx, DomMap, A0), maplist([V-X, V=X]>>true, A0, A),
        format("[gsim] found a solution after ~w oracle calls: ~w~n", [Calls, A]),
        Found = [A]
    ;   R = not_found(Calls),
        format("[gsim] no solution found within ~w oracle calls (probably none)~n", [Calls]),
        Found = []
    ),
    Solutions = Found,
    findall(I-c(Av, 0.0), ( nth0(I, FinalVec, Av), abs(Av) >= 1.0e-14 ), Pairs),
    list_to_assoc(Pairs, FinalState),

    nb_setval(grover_last_state,  FinalState),
    nb_setval(grover_last_n,      N),
    nb_setval(grover_last_fdspec, FDSpec),
    nb_setval(grover_last_dommap, DomMap),
    nb_setval(grover_last_oracle, OracleMC),

    nl,
    format("Probabilities after the final round (K=~w; simulator view, not measurable on hardware):~n", [K]),
    display_amplitude_results(FinalState, N),
    nl.


%% ============================================================
%%  Post-processor protocol entry point (QASM-based, legacy)
%% ============================================================

%% ============================================================
%%  Grover amplitude iteration
%% ============================================================

%%  grover_run(+N, +K, +Oracle, -FinalState)
%%  Initialises uniform superposition over N states and iterates K times.
grover_run(N, K, Oracle, FinalState) :-
    %% Dense, real-valued simulation. Grover's operators (phase flip and
    %% inversion about the mean) keep every amplitude real, so a plain
    %% list of N floats represents the state exactly. The oracle's
    %% verdict for a state never changes, so it is evaluated once per
    %% state up front. (The previous version rebuilt a sparse assoc and
    %% re-checked every constraint for every state in every iteration:
    %% test7, N=46464 and K=84, did not finish in 10 minutes.)
    Oracle = grover_oracle(OracleMC, DomMap),
    Amp is 1.0 / sqrt(float(N)),
    N1 is N - 1,
    numlist(0, N1, AllIdx),
    maplist([I, F]>>( eval_fd_oracle(OracleMC, DomMap, I) -> F = -1.0 ; F = 1.0 ), AllIdx, Flips),
    length(V0, N), maplist(=(Amp), V0),
    dense_iterate(K, N, Flips, V0, VF),
    %% back to the sparse Idx -> c(Re, Im) form the display code expects
    findall(I-c(A, 0.0), ( nth0(I, VF, A), abs(A) >= 1.0e-14 ), Pairs),
    list_to_assoc(Pairs, FinalState).

dense_iterate(0, _, _, V, V) :- !.
dense_iterate(K, N, Flips, V0, VF) :-
    maplist([F, A, B]>>(B is F * A), Flips, V0, V1),     %% oracle phase flip
    sum_list(V1, Sum), Mean is Sum / float(N),
    maplist([A, B]>>(B is 2.0 * Mean - A), V1, V2),      %% inversion about the mean
    K1 is K - 1,
    dense_iterate(K1, N, Flips, V2, VF).

%%  oracle_phase_flip: negate amplitude of every solution state
oracle_phase_flip(Oracle, StateIn, StateOut) :-
    assoc_to_list(StateIn, Pairs),
    maplist(flip_if_solution(Oracle), Pairs, NewPairs),
    list_to_assoc(NewPairs, StateOut).

flip_if_solution(marked(Marked), Idx-c(Re, Im), Idx-NewAmp) :- !,
    ( get_assoc(Idx, Marked, _)
    ->  NewAmp = c(-Re, -Im)
    ;   NewAmp = c(Re, Im)
    ).
flip_if_solution(grover_oracle(OracleMC, DomMap), Idx-c(Re, Im), Idx-NewAmp) :-
    ( eval_fd_oracle(OracleMC, DomMap, Idx)
    ->  NewAmp = c(-Re, -Im)
    ;   NewAmp = c(Re, Im)
    ).

%%  eval_fd_oracle: decode index to variable assignment, run pcode
eval_fd_oracle(OracleMC, DomMap, Index) :-
    decode_index(Index, DomMap, Assignment),
    pcode_eval(OracleMC, Assignment).

decode_index(Index, DomMap, Assignment) :-
    decode_index_(DomMap, Index, RevAss, _),
    reverse(RevAss, Assignment).

decode_index_([], Idx, [], Idx).
decode_index_([Var-Values|Rest], Idx, [Var-Val|Acc], Remaining) :-
    length(Values, DomSize),
    RelVal is Idx mod DomSize,
    nth0(RelVal, Values, Val),
    NIdx is Idx // DomSize,
    decode_index_(Rest, NIdx, Acc, Remaining).

%%  grover_diffuse: Grover reflection  a_i -> 2*mean - a_i
grover_diffuse(N, Sin, Sout) :-
    assoc_to_list(Sin, Pairs),
    sum_all_amplitudes(Pairs, 0.0, 0.0, SumR, SumI),
    MR is SumR / float(N),
    MI is SumI / float(N),
    %% Reflect about the mean over ALL N basis states, not just the
    %% stored ones: a state whose amplitude passed through zero was
    %% pruned from the sparse map, but 2*mean - 0 is not zero, so it
    %% must come back. (Reflecting only stored keys lost e.g. all 12
    %% solutions of x =\= y on 0..3 after one iteration: 0% not 75%.)
    N1 is N - 1, numlist(0, N1, AllIdx),
    maplist([Idx, Idx-c(R,I)]>>( get_assoc(Idx, Sin, c(R,I)) -> true ; R = 0.0, I = 0.0 ),
            AllIdx, AllPairs),
    reflect_all(AllPairs, MR, MI, NewPairs),
    prune_all(NewPairs, t, Sout).

sum_all_amplitudes([], SR, SI, SR, SI).
sum_all_amplitudes([_-c(R,I)|Rest], SR0, SI0, SR, SI) :-
    SR1 is SR0 + R, SI1 is SI0 + I,
    sum_all_amplitudes(Rest, SR1, SI1, SR, SI).

reflect_all([], _, _, []).
reflect_all([Idx-c(R,I)|Rest], MR, MI, [Idx-c(NR,NI)|NewRest]) :-
    NR is 2.0*MR - R, NI is 2.0*MI - I,
    reflect_all(Rest, MR, MI, NewRest).

prune_all([], S, S).
prune_all([Idx-c(R,I)|Rest], S0, S) :-
    ( abs(R) + abs(I) < 1.0e-14 ->
        prune_all(Rest, S0, S)
    ;   put_assoc(Idx, S0, c(R,I), S1),
        prune_all(Rest, S1, S)
    ).


%% ============================================================
%%  Result display
%% ============================================================

display_amplitude_results(State, N) :-
    assoc_to_list(State, Pairs),
    UniformP is 1.0 / float(N),
    Thresh is 2.0 * UniformP,
    include(above_thresh(Thresh), Pairs, Notable),
    exclude(above_thresh(Thresh), Pairs, Background),
    length(Background, NBg),
    Show is min(30, NBg),
    length(ShowBg, Show), append(ShowBg, _, Background),
    forall(member(Idx-c(R, I), ShowBg),
        ( P is R*R + I*I, Pct is P * 100.0,
          format("  |~w> : ~4f%~n", [Idx, Pct]) )),
    Hidden is NBg - Show,
    ( Hidden > 0
    ->  format("  ... (~w more background states not shown)~n", [Hidden])
    ;   true
    ),
    ( Notable \= []
    ->  format("  --- Notable states (above 2x uniform): ---~n"),
        forall(member(Idx-c(R, I), Notable),
            ( P is R*R + I*I, Pct is P * 100.0,
              format("  |~w> : ~4f%~n", [Idx, Pct]) ))
    ;   format("  (no states above 2x uniform)~n")
    ).


%% ============================================================
%%  Post-processing helpers (usable from REPL after a simulation)
%% ============================================================

%%  grover_decode(+StateIdx, -Assignment)
%%
%%  Decodes a state index from the last Grover simulation into a
%%  variable assignment, using the FDSpec that was active when the
%%  circuit ran.
%%
%%  Example (after queens(4) simulates):
%%    ?- grover_decode(141, A).
%%    A = [q0=1, q1=3, q2=0, q3=2]
grover_decode(Idx, Assignment) :-
    ( nb_getval(grover_last_dommap, DomMap) -> true
    ;   format("[grover_decode] No simulation result stored yet.~n"), fail ),
    decode_index(Idx, DomMap, RawAssign),
    raw_to_assign(RawAssign, Assignment).

raw_to_assign([], []).
raw_to_assign([V-Val|Rest], [V=Val|Out]) :- raw_to_assign(Rest, Out).


%%  grover_top(+N)
%%
%%  Prints the top N states by probability from the last simulation,
%%  with each state decoded to its variable assignment.
%%
%%  Example:
%%    ?- grover_top(5).
%%    Top 5 states by probability:
%%      |141> : 25.5000%  [q0=1, q1=3, q2=0, q3=2]  ** solution **
%%      |114> : 25.5000%  [q0=2, q1=0, q2=3, q3=1]  ** solution **
%%      ...
grover_top(N) :-
    ( nb_getval(grover_last_state,  State)  -> true
    ;   format("[grover_top] No simulation result stored yet. Run a Grover circuit first.~n"), fail ),
    nb_getval(grover_last_n,      TotalN),
    nb_getval(grover_last_fdspec, FDSpec),
    nb_getval(grover_last_dommap, _DomMap),
    assoc_to_list(State, Pairs),
    pairs_probs(Pairs, PIdxPairs),
    msort(PIdxPairs, Sorted),
    reverse(Sorted, Descending),
    %% Show at most as many states as exist: asking for top(5) of a
    %% 4-state space used to fail (length/append cannot take 5 of 4).
    length(Descending, NAvail), Show is min(N, NAvail),
    length(TopN, Show), append(TopN, _, Descending),
    format("Top ~w states by probability (out of ~w):~n", [Show, TotalN]),
    %% labels: each displayed state checked against the constraints
    rp_fd_oracle_mc(FDSpec, OracleMC),
    maplist(show_grover_state(check(OracleMC)), TopN).


%% ============================================================
%%  Helper predicates replacing lambdas for module compatibility
%% ============================================================

multiply_sizes(S, A, P) :- P is A * S.

%% dom_to_dommap_entry is no longer used for decoding (rp_fd_oracle_mc
%% now returns Var-Values directly). Kept for domain-size calculation only.
dom_to_dommap_entry(dom(V, L, H), V-(L, S)) :- S is H - L + 1.

init_state_entry(Amp, I, A0, A1) :- put_assoc(I, A0, c(Amp, 0.0), A1).

sum_amplitudes(_-c(R, I), c(SR, SI), c(NR, NI)) :-
    NR is SR + R, NI is SI + I.

reflect_amplitude(MR, MI, Idx-c(R, I), Idx-c(NR, NI)) :-
    NR is 2.0 * MR - R, NI is 2.0 * MI - I.

prune_tiny(Idx-Amp, A0, A1) :-
    Amp = c(R2, I2),
    ( abs(R2) + abs(I2) < 1.0e-14 -> A1 = A0 ; put_assoc(Idx, A0, Amp, A1) ).

above_thresh(Thresh, _-c(R, I)) :- P is R*R + I*I, P > Thresh.

pair_prob(Idx-c(R,I), P-Idx) :- P is R*R + I*I.

show_grover_state(Solutions, P-Idx) :-
    grover_decode(Idx, Assignment),
    Pct is P * 100.0,
    ( is_solution(Assignment, Solutions) ->
        Tag = "  ** solution **"
    ;   Tag = ""
    ),
    format("  |~w> : ~4f%  ~w~w~n", [Idx, Pct, Assignment, Tag]).

is_solution(Assignment, check(pcode(Spec, _))) :- !,
    maplist([V=X, V-X]>>true, Assignment, A),
    catch(rp_pcode:pcode_eval(pcode(Spec, []), A), _, fail).
is_solution(Assignment, Solutions) :-
    member(Sol, Solutions),
    all_match(Assignment, Sol).

all_match([], _).
all_match([V=Val|Rest], Sol) :-
    member(V-Val, Sol),
    all_match(Rest, Sol).

product_list([], P, P).
product_list([S|Rest], Acc, P) :- Acc1 is Acc * S, product_list(Rest, Acc1, P).

pairs_probs([], []).
pairs_probs([Idx-c(R,I)|Rest], [P-Idx|PRest]) :-
    P is R*R + I*I,
    pairs_probs(Rest, PRest).

dommap_size(_Var-Values, Size) :- length(Values, Size).

%% Exponential search with unknown M (Boyer, Brassard, Hoyer, Tapp 1998):
%% K uniform in 0..ceil(m)-1, measure, check; on failure m := min(6/5 m,
%% sqrt N). Same algorithm as QCLP_G's grover_search/3.
bbht_round(M, SqrtN, N, Flips, V0, Budget, Round, Calls0, R, VF, K) :-
    KMax is max(1, ceiling(M)), KTop is KMax - 1,
    random_between(0, KTop, K1),
    dense_iterate(K1, N, Flips, V0, V1),
    sample_index(V1, I),
    Calls1 is Calls0 + K1,
    nth0(I, Flips, F),
    (   F < 0
    ->  format("[gsim]   round ~w: K=~w, measured |~w>: checked, a solution~n", [Round, K1, I]),
        R = found(I, Calls1), VF = V1, K = K1
    ;   format("[gsim]   round ~w: K=~w, measured |~w>: checked, not a solution~n", [Round, K1, I]),
        (   Calls1 >= Budget
        ->  R = not_found(Calls1), VF = V1, K = K1
        ;   M1 is min(M * 6 / 5, SqrtN), Round1 is Round + 1,
            bbht_round(M1, SqrtN, N, Flips, V0, Budget, Round1, Calls1, R, VF, K)
        )
    ).

sample_index(V, I) :- random(R), sample_acc(V, R, 0, 0.0, I).
sample_acc([A|As], R, I0, Acc0, I) :-
    Acc is Acc0 + A*A,
    ( ( R < Acc ; As == [] ) -> I = I0 ; I1 is I0 + 1, sample_acc(As, R, I1, Acc, I) ).
