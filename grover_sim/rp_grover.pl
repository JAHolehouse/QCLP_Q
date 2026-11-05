%% =============================================================================
%%  rp_grover.pl  --  Grover iteration count
%%
%%  rp_grover_iterations_m(+N, +M, -K)
%%
%%  Computes the optimal number of Grover iterations K for a search space
%%  of size N with M solutions.
%%
%%  See the comment on rp_grover_iterations_m/3 below for the rule.
%% =============================================================================

:- module(rp_grover, [rp_grover_iterations_m/3]).

%%  rp_grover_iterations_m(+N, +M, -K)
%%  Grover iteration count for M solutions in N states.
%%
%%  K MAXIMISES the success probability sin^2((2K+1)*theta),
%%  theta = asin(sqrt(M/N)), over K >= 1, taking the smallest K on a
%%  tie. This one rule is shared, word for word, by QCLP_G
%%  (qclp_gates/rp_grover.pl) and QCLP_Q (grover_sim/rp_grover.pl).
%%
%%  History:
%%    * QCLP_G took the FIRST K >= 1 with P >= 50%, so it could stop
%%      short of the best K (queens4_anchor1: K=3, 59%; K=6, 99.7%).
%%    * QCLP_Q used the closed form round(pi/4*sqrt(N/M) - 1/2) clamped
%%      to K >= 1, which lands in a dead zone when solutions are common
%%      (M=12, N=16: K=1, 0%). Its fix allowed K = 0 instead.
%%    * K = 0 is NOT used here: for a circuit compiler it means an
%%      exported "Grover circuit" with no oracle at all. For moderate
%%      M/N some K >= 1 matches or beats K = 0 (M=12, N=16: K=2, 75%;
%%      M=13, N=16: K=3, 99.996% vs 81%). When nearly every state is a
%%      solution, any iteration lowers P (M=319, N=327: K=0 97.6%, best
%%      K >= 1 79.4%); such problems do not need Grover at all.
%%  M = 0: K = 1 by convention (nothing can be amplified).
rp_grover_iterations_m(_, M, 1) :- M =< 0, !.
rp_grover_iterations_m(N, M, K) :-
    Theta is asin(sqrt(min(1.0, float(M) / float(N)))),
    %% M/N =< 1/2 (theta =< pi/4): one smooth peak, inside the first
    %% period K = 1 .. pi/(2 theta). M/N > 1/2: the period is under two
    %% steps, so P(K) jumps about from one K to the next; search a short
    %% fixed range instead (M=13, N=16: K=2 gives 38%, K=3 gives 99.996%).
    ( Theta =< pi / 4 + 1.0e-12
    ->  KMax is max(1, ceiling(pi / (2.0 * Theta)))
    ;   KMax = 8
    ),
    findall(P, ( between(1, KMax, Ki), P is sin((2*Ki+1)*Theta)**2 ), Ps),
    max_list(Ps, PMax),
    %% smallest K within 1e-9 of the best: same success probability,
    %% shorter circuit
    nth1(K, Ps, PK), PK >= PMax - 1.0e-9, !.
