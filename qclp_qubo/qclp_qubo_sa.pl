% =============================================================================
% qclp_QUBO_SA -- a small simulated-annealing solver for QUBOs.
% =============================================================================
% Used as a classical "verifier" oracle for QUBOs produced by qclp_qubo.pl:
% it does NOT require any external solver (D-Wave / Ocean / etc), just plain
% SWI-Prolog, so the compiled QUBO can be sanity-checked against the known
% answers from clpfd_evaluator.pl.
%
% Algorithm: standard bit-flip simulated annealing with an exact O(1)
% delta-energy update per proposed flip (using a precomputed adjacency list
% of quadratic neighbors for each binary variable), geometric temperature
% schedule, Metropolis acceptance. Tracks and returns the best (lowest
% energy) bitstring seen across the whole run.
% =============================================================================
:- module(qclp_qubo_sa, [
    qubo_anneal/4,   % +Qubo, +NBits, -BestBits, -BestEnergy
    qubo_anneal/5,   % +Qubo, +NBits, +Options, -BestBits, -BestEnergy
    qubo_multi_anneal/5  % +Qubo, +NBits, +Options, +NumRestarts, -BestBits-BestEnergy
]).

:- use_module(library(apply)).
:- use_module(library(lists)).
:- use_module(qclp_qubo, [qubo_energy/3]).

option_default(Key, Options, Default, Value) :-
    Opt =.. [Key, V],
    ( member(Opt, Options) -> Value = V ; Value = Default ).

%% ---------------------------------------------------------------------------
%% qubo_anneal(+Qubo, +NBits, -BestBits, -BestEnergy)
%% qubo_anneal(+Qubo, +NBits, +Options, -BestBits, -BestEnergy)
%%   Options:
%%     iterations(N)   default 20000
%%     t0(Float)       default 10.0   (initial temperature)
%%     t1(Float)       default 0.05   (final temperature)
%% ---------------------------------------------------------------------------
qubo_anneal(Qubo, NBits, BestBits, BestEnergy) :-
    qubo_anneal(Qubo, NBits, [], BestBits, BestEnergy).

qubo_anneal(qubo(Const,Lin,Quad), NBits, Options, BestBits, BestEnergy) :-
    option_default(iterations, Options, 20000, Iters),
    max_abs_coeff(Lin, Quad, MaxAbs),
    DefaultT0 is max(MaxAbs, 1.0),
    option_default(t0, Options, DefaultT0, T0),
    DefaultT1 is T0 / 1000,
    option_default(t1, Options, DefaultT1, T1),
    option_default(blocks, Options, [], Blocks),
    exclude([B]>>(B=[]), Blocks, Blocks1),  % drop blocks of size 0/1 below
    include([B]>>(B=[_,_|_]), Blocks1, BlockMoves),
    build_lin_array(Lin, NBits, LinArr),
    build_neighbors(NBits, Quad, NeighArr),
    init_bits(NBits, Bits0),
    qubo_energy(qubo(Const,Lin,Quad), Bits0, E0),
    Ratio is (T1/T0) ** (1.0/max(1,Iters)),
    anneal_loop(Iters, T0, Ratio, NBits, LinArr, NeighArr, BlockMoves, Bits0, E0, Bits0, E0, BestBits, BestEnergy).

% max_abs_coeff(+Lin, +Quad, -MaxAbs) : largest |coefficient| across all
% linear and quadratic terms (used to set a sensible initial temperature).
max_abs_coeff(Lin, Quad, MaxAbs) :-
    findall(A, ( member(_-C,Lin), A is abs(C) ), As0),
    findall(A, ( member(_-C,Quad), A is abs(C) ), As1),
    append(As0,As1,As),
    ( As == [] -> MaxAbs = 1.0 ; max_list(As, MaxAbs) ).

%% qubo_multi_anneal(+Qubo, +NBits, +Options, +NumRestarts, -BestBits-BestEnergy)
%%   Runs qubo_anneal NumRestarts times and keeps the overall best.
qubo_multi_anneal(Qubo, NBits, Options, NumRestarts, BestBits-BestEnergy) :-
    numlist(1, NumRestarts, Runs),
    foldl(multi_step(Qubo,NBits,Options), Runs, none-none, BestBits-BestEnergy0),
    ( BestEnergy0 == none -> qubo_anneal(Qubo,NBits,Options,BestBits,BestEnergy)
    ; BestEnergy = BestEnergy0
    ).

multi_step(Qubo,NBits,Options,_, BestSoFar-BestE, NewBest-NewE) :-
    qubo_anneal(Qubo,NBits,Options,Bits,E),
    ( (BestE == none ; E < BestE) -> NewBest=Bits, NewE=E ; NewBest=BestSoFar, NewE=BestE ).

%% ---------------------------------------------------------------------------
%% Setup helpers
%% ---------------------------------------------------------------------------
% build_lin_array(+Lin, +NBits, -LinArr) : LinArr is a list of length NBits,
% LinArr[I] = linear coefficient of variable I (0 if absent).
build_lin_array(Lin, NBits, LinArr) :-
    list_to_assoc(Lin, Assoc0),
    Hi is NBits-1,
    numlist(0, Hi, Idxs),
    maplist(lin_lookup(Assoc0), Idxs, LinArr).

lin_lookup(Assoc, I, C) :- ( get_assoc(I,Assoc,V) -> C=V ; C=0 ).

% build_neighbors(+NBits, +Quad, -NeighArr) : NeighArr is a list of length
% NBits, NeighArr[I] = list of J-Coeff pairs for every quadratic term
% involving I (J = the *other* variable, Coeff = its coefficient).
build_neighbors(NBits, Quad, NeighArr) :-
    Hi is NBits-1,
    numlist(0, Hi, Idxs),
    maplist(neighbors_for(Quad), Idxs, NeighArr).

neighbors_for(Quad, I, Neigh) :-
    findall(J-C, ( member((A-B)-C, Quad), ( A==I -> J=B ; B==I -> J=A ; fail ) ), Neigh).

% init_bits(+NBits, -Bits) : random initial 0/1 assignment.
init_bits(NBits, Bits) :-
    numlist(1, NBits, Idxs),
    maplist([_,B]>>(random(R), (R<0.5 -> B=0 ; B=1)), Idxs, Bits).

%% ---------------------------------------------------------------------------
%% Annealing loop
%%   With probability 0.5 (when BlockMoves is non-empty), perform a
%%   "block-swap" move: pick a one-hot block, pick its current 1-bit (if
%%   any) and a different bit in the block, and swap them in a single
%%   combined move. This lets the search move directly between two valid
%%   one-hot encodings without crossing the P_oh barrier of an invalid
%%   intermediate state. Otherwise, perform a plain single-bit flip.
%% ---------------------------------------------------------------------------
anneal_loop(0, _, _, _, _, _, _, _, _, BestBits, BestE, BestBits, BestE) :- !.
anneal_loop(Iters, T, Ratio, NBits, LinArr, NeighArr, BlockMoves, Bits, E, BestBits, BestE, FinalBits, FinalE) :-
    random(0.0,1.0,RM),
    ( BlockMoves \== [], RM < 0.34 ->
        random_member(Block, BlockMoves),
        propose_swap(Block, Bits, LinArr, NeighArr, Delta, Bits1)
    ; BlockMoves \== [], RM < 0.67, BlockMoves = [_,_|_] ->
        propose_block_pair_swap(BlockMoves, Bits, LinArr, NeighArr, Delta, Bits1)
    ;   random(0.0, 1.0, R0), I is min(NBits-1, floor(R0*NBits)),
        flip_delta(Bits, LinArr, NeighArr, I, Delta),
        flip_bit(Bits, I, Bits1)
    ),
    ( Delta =< 0 -> Accept = true
    ; T =< 0 -> Accept = false
    ; random(0.0,1.0,R), P is exp(-Delta/T), Accept = (R < P)
    ),
    ( Accept -> Bits2 = Bits1, E1 is E + Delta
    ;   Bits2 = Bits, E1 = E
    ),
    ( E1 < BestE -> BestBits1 = Bits2, BestE1 = E1 ; BestBits1 = BestBits, BestE1 = BestE ),
    T1 is T * Ratio,
    Iters1 is Iters - 1,
    anneal_loop(Iters1, T1, Ratio, NBits, LinArr, NeighArr, BlockMoves, Bits2, E1, BestBits1, BestE1, FinalBits, FinalE).

% flip_delta(+Bits, +LinArr, +NeighArr, +I, -Delta)
%   Delta = energy change from flipping bit I in Bits.
flip_delta(Bits, LinArr, NeighArr, I, Delta) :-
    nth0(I, Bits, Xi),
    nth0(I, LinArr, LinI),
    nth0(I, NeighArr, NeighI),
    foldl(neigh_sum(Bits), NeighI, 0, NeighSum),
    ( Xi == 0 -> Sign = 1 ; Sign = -1 ),
    Delta is Sign * (LinI + NeighSum).

% propose_swap(+Block, +Bits, +LinArr, +NeighArr, -Delta, -Bits2)
%   Pick the (first) currently-1 bit and a random currently-0 bit within
%   Block, and compute the combined delta-energy of flipping both (in
%   sequence, so cross terms between them are accounted for exactly).
%   If Block has no 1-bit or no 0-bit (degenerate/invalid state), falls
%   back to a single random-bit flip within the block.
propose_swap(Block, Bits, LinArr, NeighArr, Delta, Bits2) :-
    partition([Idx]>>(nth0(Idx,Bits,1)), Block, OnIdxs, OffIdxs),
    ( OnIdxs = [On|_], OffIdxs \== [] ->
        random_member(Off, OffIdxs),
        flip_delta(Bits, LinArr, NeighArr, On, DeltaOn),
        flip_bit(Bits, On, BitsA),
        flip_delta(BitsA, LinArr, NeighArr, Off, DeltaOff),
        flip_bit(BitsA, Off, Bits2),
        Delta is DeltaOn + DeltaOff
    ;   % degenerate: fall back to a single flip of a random index in Block
        random_member(I, Block),
        flip_delta(Bits, LinArr, NeighArr, I, Delta),
        flip_bit(Bits, I, Bits2)
    ).

% propose_block_pair_swap(+BlockMoves, +Bits, +LinArr, +NeighArr, -Delta, -Bits2)
%   Pick two distinct blocks of equal size and, if each currently has
%   exactly one bit set at the SAME relative position within its block,
%   "swap their values": for block A's on-position pA and block B's
%   on-position pB (pA \== pB), turn off A[pA]/on A[pB], and off B[pB]/on
%   B[pA]. This is the natural "swap the values of two cells" move for
%   permutation-style CSPs (e.g. sudoku rows/columns/blocks). Falls back
%   to a plain block-swap (propose_swap/6) on a random block if no
%   suitable pair is found.
propose_block_pair_swap(BlockMoves, Bits, LinArr, NeighArr, Delta, Bits2) :-
    random_member(BlockA, BlockMoves),
    findall(B, ( member(B,BlockMoves), B \== BlockA, same_length(B,BlockA) ), Candidates),
    ( Candidates \== [],
      on_position(BlockA, Bits, PA),
      random_member(BlockB, Candidates),
      on_position(BlockB, Bits, PB),
      PA \== PB ->
        nth0(PA, BlockA, A_on), nth0(PB, BlockA, A_off),
        nth0(PB, BlockB, B_on), nth0(PA, BlockB, B_off),
        flip_delta(Bits, LinArr, NeighArr, A_on, D1), flip_bit(Bits, A_on, Bits1),
        flip_delta(Bits1, LinArr, NeighArr, A_off, D2), flip_bit(Bits1, A_off, Bits2a),
        flip_delta(Bits2a, LinArr, NeighArr, B_on, D3), flip_bit(Bits2a, B_on, Bits2b),
        flip_delta(Bits2b, LinArr, NeighArr, B_off, D4), flip_bit(Bits2b, B_off, Bits2),
        Delta is D1+D2+D3+D4
    ;   propose_swap(BlockA, Bits, LinArr, NeighArr, Delta, Bits2)
    ).

% on_position(+Block, +Bits, -Pos) : Pos is the index-into-Block of the
% (first) element of Block whose bit is 1, or 0 if none is set.
on_position(Block, Bits, Pos) :-
    ( nth0(P, Block, Idx), nth0(Idx,Bits,1) -> Pos = P ; Pos = 0 ).

neigh_sum(Bits, J-C, Acc, Acc2) :- nth0(J,Bits,Xj), Acc2 is Acc + C*Xj.

flip_bit(Bits, I, Bits1) :-
    nth0(I, Bits, X), X1 is 1-X,
    same_length(Bits, Bits1),
    flip_bit_(Bits, I, X1, Bits1).

flip_bit_([_|T], 0, X1, [X1|T]) :- !.
flip_bit_([H|T], I, X1, [H|R]) :- I>0, I1 is I-1, flip_bit_(T,I1,X1,R).
