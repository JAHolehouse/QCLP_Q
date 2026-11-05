% =============================================================================
% qaoa_run.pl  --  Easy QAOA simulation runner
% =============================================================================
%
% Load with:    ?- [qcpl_start].
%
%   
% Then run with:
%   
%   qsim(File)            % auto-detect .clp / .qbo / .qasm
%   qsim(File, Options)
%
% Options (all optional):
%   shots(N)          samples to draw          (default: 1000)
%   p(N)              QAOA layers              (default: 1)
%   gamma(List)       gamma angles per layer   (default: [0.5])
%   beta(List)        beta angles per layer    (default: [0.3])
%   top(N)            top results to show      (default: 5)
%   amplitudes(true)  show full amplitudes
%   outfile(Path)     write generated .qasm here
%
% Examples:
%   ?- qsim('tests/tiny_neq.clp').
%   ?- qsim('tests/sparse_test.qbo').
%   ?- qsim('qaoa/maxcut.qasm').
%   ?- qsim('tests/maxcut.clp', [shots(2000), top(3)]).
%   ?- qsim('tests/sparse_test.qbo', [p(2), gamma([0.6,0.4]), beta([0.3,0.2])]).
%
% SV simulation is practical up to ~10 qubits.  Larger problems will have
% their QASM generated and saved, but simulation will be skipped.
% =============================================================================

:- module(qcpl, [qsim/1, qsim/2, gsim/1, gsim/2, eval/1, qsim_run/1, qsim_run/2, info/0]).

% ------------------------------------------------------------------
%  Paths -- edit these to match your installation
% ------------------------------------------------------------------

qubo_dir('qclp_qubo').
sv_dir('sv_sim').
clp_dir('clp_evaluator').
grover_dir('grover_sim').

sv_limit(12).   % max qubits for statevector simulation

% ------------------------------------------------------------------
%  Module loading
% ------------------------------------------------------------------

load_mod(Dir, Mod) :-
    atomic_list_concat([Dir, '/', Mod, '.pl'], Path),
    use_module(Path).

%% sv_sim modules MUST be loaded before qclp_qubo to avoid clpfd arithmetic conflicts
:- qubo_dir(QD), sv_dir(SD), clp_dir(CD), grover_dir(GD),
   nb_setval(rprolog_dir, SD),
   load_mod(SD, 'sv_util'),
   load_mod(SD, 'sv_sim'),
   load_mod(SD, 'sv_run'),
   load_mod(SD, 'qasm3_macro_pp'),
   load_mod(GD, 'rp_fd'),
   load_mod(GD, 'rp_pcode'),
   load_mod(GD, 'rp_grover'),
   load_mod(GD, 'qsim_pp_grover'),
   load_mod(QD, 'qclp_qubo'),
   load_mod(QD, 'qclp_qubo_sa'),
   load_mod(QD, 'qubo_qaoa_qasm3'),
   load_mod(CD, 'eval_clp').

% ------------------------------------------------------------------
%  Public API
% ------------------------------------------------------------------

qsim(Source) :- qsim(Source, []).

qsim(Source, Options) :-
    atom(Source),
    file_name_extension(_, Ext, Source),
    ( Ext == clp  -> run_from_clp(Source,  Options)
    ; Ext == qbo  -> run_from_qbo(Source,  Options)
    ; Ext == qasm -> run_from_qasm(Source, Options)
    ; format("~nERROR: unknown extension '.~w' -- expected .clp, .qbo or .qasm~n", [Ext]),
      fail
    ).

% ------------------------------------------------------------------
%  gsim -- Grover pcode simulator (no qubit limit)
% ------------------------------------------------------------------

%%  gsim(+ClpFile)
%%  gsim(+ClpFile, +Options)
%%
%%  Simulates a .clp problem using the Grover amplitude iteration
%%  directly on the FD search space.  No QASM or statevector is
%%  involved, so there is no qubit limit.
%%
%%  Options:
%%    top(N)    show top N states by probability  (default: 5)

gsim(ClpFile) :- gsim(ClpFile, []).

gsim(ClpFile, Opts) :-
    atom(ClpFile),
    file_name_extension(_, Ext, ClpFile),
    ( Ext == clp ->
        run_grover_from_clp(ClpFile, Opts)
    ;   format("~nERROR: gsim requires a .clp file (got .~w)~n", [Ext]), fail
    ).

run_grover_from_clp(ClpFile, Opts) :-
    format("~n[gsim] Loading ~w~n", [ClpFile]),
    ( catch(qclp_qubo:read_problem_spec(ClpFile, Spec, VarNames), E,
            (format("  ERROR loading spec: ~w~n", [E]), fail)) ->
        %% Bind each source variable name (StartA, M, N, ...) to itself as
        %% an atom, so gsim can look it up. It used to stay an unbound
        %% Prolog variable, which gsim's lookup then silently bound to
        %% the first value it saw (bestcost errored; test5/test6 were wrong).
        maplist([Name=Var]>>(Var = Name), VarNames)
    ;   fail
    ),
    ( catch(qsim_pp_grover:run_fdspec(Spec, Opts, grover_result(_Found, _FinalState)),
            E2, (format("  ERROR in Grover sim: ~w~n", [E2]), fail)) ->
        get_opt(top, Opts, 5, TopN),
        qsim_pp_grover:grover_top(TopN)
    ;   fail
    ).

% ------------------------------------------------------------------
%  .clp -> QUBO -> QASM -> simulate
% ------------------------------------------------------------------

run_from_clp(ClpFile, Opts) :-
    format("~n[1/3] Compiling ~w~n", [ClpFile]),
    ( catch(qclp_qubo:compile_qubo(ClpFile, Opts, Result), E,
            (format("  ERROR: ~w~n", [E]), fail)) ->
        Result = qubo(Const,Lin,Quad)-_VarTable-NBits,
        length(Lin, NL), length(Quad, NQ),
        format("  ~w qubits, ~w linear, ~w quadratic terms, constant=~w~n",
               [NBits, NL, NQ, Const]),
        file_name_extension(Stem, _, ClpFile),
        atom_concat(Stem, '.qbo', QboFile),
        qclp_qubo:qubo_write(Result, QboFile, ClpFile),
        format("  wrote ~w~n", [QboFile]),
        run_from_qbo(QboFile, Opts)
    ;   fail
    ).

% ------------------------------------------------------------------
%  .qbo -> QASM -> simulate
% ------------------------------------------------------------------

run_from_qbo(QboFile, Opts) :-
    format("~n[2/3] Generating QAOA QASM from ~w~n", [QboFile]),
    ( member(outfile(QasmFile), Opts) -> true
    ;   file_name_extension(Stem, _, QboFile),
        atom_concat(Stem, '.qasm', QasmFile)
    ),
    get_opt(p,     Opts, 1,     P),
    get_opt(gamma, Opts, [0.5], Gamma),
    get_opt(beta,  Opts, [0.3], Beta),
    QasmOpts = [p(P), gamma(Gamma), beta(Beta), outfile(QasmFile)],
    ( catch(qubo_qaoa_qasm3:qaoa3(QboFile, QasmOpts), E,
            (format("  ERROR: ~w~n", [E]), fail)) ->
        format("  wrote ~w~n", [QasmFile]),
        %% The .qbo is known here, so pass it on. (It used to be
        %% re-guessed from the .qasm name, which failed whenever
        %% outfile(Path) put the circuit somewhere else.)
        run_from_qasm(QasmFile, QboFile, Opts)
    ;   fail
    ).

% ------------------------------------------------------------------
%  .qasm -> expand macros -> simulate
% ------------------------------------------------------------------

run_from_qasm(QasmFile, Opts) :-
    qbo_for_qasm(QasmFile, MaybeQbo),
    run_from_qasm(QasmFile, MaybeQbo, Opts).

run_from_qasm(QasmFile, MaybeQbo, Opts) :-
    sv_run:qasm3_nqubits_from_file(QasmFile, NQ),
    sv_limit(Limit),
    ( NQ > Limit ->
        format("~n[3/3] ~w qubits -- exceeds SV limit (~w), skipping simulation~n",
               [NQ, Limit]),
        format("  QASM ready at: ~w~n", [QasmFile])
    ;
        format("~n[3/3] Simulating ~w (~w qubits)~n", [QasmFile, NQ]),
        %% Macro-expand in memory, as sv_run:qsim_run/2 does. (This used
        %% to write a <name>_flat.qasm file beside every circuit.)
        read_file_to_string(QasmFile, Src, []),
        qasm3_macro_pp:qasm3_expand_string(Src, Flat),
        atom_string(FlatAtom, Flat),
        sv_sim:sv_run_qasm(FlatAtom, State),
        display_results(State, NQ, MaybeQbo, Opts)
    ).

% ------------------------------------------------------------------
%  Results
% ------------------------------------------------------------------

display_results(State, NQ, MaybeQbo, Opts) :-
    get_opt(amplitudes, Opts, false, Amps),
    ( Amps == true ->
        sv_sim:sv_amplitudes(State, NQ)
    ;
        get_opt(shots, Opts, 1000, Shots),
        get_opt(top,   Opts, 5,    TopN),
        format("~n  Sampling ~w shots...~n", [Shots]),
        sv_sim:sv_sample(State, NQ, Shots, Outcomes),
        tally_sorted(Outcomes, Tally),
        length(Tally, NDistinct),
        format("  ~w distinct outcomes~n~n", [NDistinct]),
        show_top(Tally, TopN, Shots, NQ, MaybeQbo)
    ).

%% Try several naming conventions to find the matching .qbo for a .qasm
qbo_for_qasm(QasmFile, QboFile) :-
    file_base_name(QasmFile, BaseName),
    file_directory_name(QasmFile, Dir),
    ( atom_concat(Stem, '.qasm',      BaseName) -> true
    ; atom_concat(Stem, '_flat.qasm', BaseName) -> true
    ; Stem = BaseName
    ),
    atom_concat(Stem, '.qbo', QboBase),
    %% Search: same dir, then sibling tests/ dir relative to qubo_dir
    qubo_dir(QD),
    (   atom_concat(Dir, '/', DirSlash), atom_concat(DirSlash, QboBase, Q1), exists_file(Q1) -> QboFile = Q1
    ;   atom_concat(QD, '/../tests/', TP), atom_concat(TP, QboBase, Q2), exists_file(Q2) -> QboFile = Q2
    ;   QboFile = none
    ).

show_top(Tally, TopN, Total, NQ, MaybeQbo) :-
    show_top_(Tally, TopN, Total, NQ, MaybeQbo, 0).

%% Only valid one-hot assignments count toward TopN.
%% Invalid states (multi-bit or empty) are silently skipped and tallied.
show_top_(_, 0, _, _, _, Skipped) :- !,
    ( Skipped > 0 ->
        format("  (~w invalid/undecodable outcomes not shown)~n", [Skipped])
    ; true ).
show_top_([], _, _, _, _, Skipped) :- !,
    ( Skipped > 0 ->
        format("  (~w invalid/undecodable outcomes not shown)~n", [Skipped])
    ; true ).
show_top_([Count-Idx | Rest], N, Total, NQ, MaybeQbo, Skipped) :-
    Pct is Count * 100.0 / Total,
    ( MaybeQbo \= none,
      catch(decode_shot(MaybeQbo, NQ, Idx, Assign, Energy, Valid), _, fail) ->
        ( Valid == true ->
            format("  (~1f%)  cost=~w  ~w~n", [Pct, Energy, Assign]),
            Skipped1 = Skipped,
            N1 is N - 1
        ;
            Skipped1 is Skipped + 1,
            N1 = N
        )
    ;
        format_bitstring(Idx, NQ, BS),
        format("  (~1f%)  |~w>~n", [Pct, BS]),
        Skipped1 = Skipped,
        N1 is N - 1
    ),
    show_top_(Rest, N1, Total, NQ, MaybeQbo, Skipped1).

% ------------------------------------------------------------------
%  QUBO decoding helpers
% ------------------------------------------------------------------

qubo_constant(QboFile, Const) :-
    read_file_to_string(QboFile, S, []),
    split_string(S, "\n", "", Lines),
    member(L, Lines), string_concat("constant ", CS, L),
    number_string(Const, CS), !.
qubo_constant(_, 0).

decode_shot(QboFile, _NQ, Idx, Assign, Energy, Valid) :-
    read_vartable(QboFile, VT),
    %% All variable keys declared in the vartable
    findall(K, member(_-K=_, VT), AllKeys0),
    list_to_set(AllKeys0, AllKeys),
    %% For each key, count how many of its bits are set
    findall(K=V-Count,
        ( member(K, AllKeys),
          findall(V2, (member(B-K=V2, VT), (Idx >> B) /\ 1 =:= 1), SetVals),
          length(SetVals, Count),
          ( SetVals = [V|_] -> true ; V = none )
        ),
        KeyCounts),
    %% Valid one-hot: every key has exactly one bit set
    ( forall(member(_=_-C, KeyCounts), C =:= 1) ->
        Valid = true
    ;   Valid = false
    ),
    %% Assign: only include keys with exactly one bit set, and not the
    %% compiler's internal helper variables (names starting '_qclp_')
    findall(K=V, ( member(K=V-1, KeyCounts),
                   \+ sub_atom(K, 0, _, _, '_qclp_') ), Assign),
    qaoa_qubo_energy(QboFile, Idx, Energy).

read_vartable(QboFile, VT) :-
    read_file_to_string(QboFile, S, []),
    split_string(S, "\n", "", Lines),
    include(is_vt_line, Lines, VTLines),
    maplist(parse_vt_line, VTLines, VT).

is_vt_line(L) :-
    string_concat("%   ", Rest, L),
    split_string(Rest, " ", " ", Ps),
    include([P]>>(P \= ""), Ps, [_, ":", _, "=", _ | _]).

parse_vt_line(L, Idx-Key=Val) :-
    string_concat("%   ", Rest, L),
    split_string(Rest, " ", " ", Ps),
    include([P]>>(P \= ""), Ps, [IS, ":", KS, "=", VS | _]),
    number_string(Idx, IS), atom_string(Key, KS), number_string(Val, VS).

qaoa_qubo_energy(QboFile, BitIdx, Energy) :-
    read_file_to_string(QboFile, S, []),
    split_string(S, "\n", "", Lines),
    ( member(L, Lines), string_concat("constant ", CS, L),
      number_string(C, CS) -> true ; C = 0 ),
    findall(I-W, (member(L2, Lines), string_concat("linear ", R2, L2),
        split_string(R2, " ", "", [IS2,WS2]),
        number_string(I,IS2), number_string(W,WS2)), Lins),
    findall(I-J-W, (member(L3, Lines), string_concat("quadratic ", R3, L3),
        split_string(R3, " ", "", [IS3,JS3,WS3]),
        number_string(I,IS3), number_string(J,JS3), number_string(W,WS3)), Quads),
    qubo_linear_sum(Lins, BitIdx, C, E1),
    qubo_quad_sum(Quads, BitIdx, E1, Energy).

qubo_linear_sum([], _, Acc, Acc).
qubo_linear_sum([I-W|Rest], BitIdx, Acc, Out) :-
    B is (BitIdx >> I) /\ 1,
    Acc1 is Acc + W * B,
    qubo_linear_sum(Rest, BitIdx, Acc1, Out).

qubo_quad_sum([], _, Acc, Acc).
qubo_quad_sum([I-J-W|Rest], BitIdx, Acc, Out) :-
    Bi is (BitIdx >> I) /\ 1,
    Bj is (BitIdx >> J) /\ 1,
    Acc1 is Acc + W * Bi * Bj,
    qubo_quad_sum(Rest, BitIdx, Acc1, Out).

format_bitstring(Idx, NQ, BS) :-
    NQ1 is NQ-1, numlist(0, NQ1, Bs0), reverse(Bs0, Bs),
    %% Helper predicate, not a yall lambda: the lambda used Idx without
    %% declaring it ({Idx}/...), so Idx was unbound inside it and every
    %% call raised an instantiation error (qsim on a .qasm with no
    %% matching .qbo, or with outfile(...), crashed after sampling).
    maplist(bit_char(Idx), Bs, Cs),
    atomic_list_concat(Cs, BS).

bit_char(Idx, B, C) :-
    ( (Idx >> B) /\ 1 =:= 1 -> C = '1' ; C = '0' ).

% ------------------------------------------------------------------
%  Helpers
% ------------------------------------------------------------------

tally_sorted(Outcomes, Tally) :-
    msort(Outcomes, Sorted),
    run_length(Sorted, Pairs),
    sort(1, @>=, Pairs, Tally).

run_length([], []).
run_length([X|Xs], [N-X|Rest]) :-
    partition(=(X), Xs, Same, Other),
    length(Same, N0), N is N0+1,
    run_length(Other, Rest).

get_opt(Key, Opts, Default, Value) :-
    Opt =.. [Key, V],
    ( member(Opt, Opts) -> Value = V ; Value = Default ).

% ------------------------------------------------------------------
%  Startup banner
% ------------------------------------------------------------------
:- format("~nQCLP_Q loaded.  Type  info.  for more information.~n").

info :-
   format("~n~`=t~60|~n"),
   format("  QCLP_Q commands (available at the Prolog prompt)~n"),
   format("~`=t~60|~n"),
   format("  eval('path/filename.clp').          SWI Prolog clp(fd)~n"),
   format("  gsim('path/filename.clp')           Grover pcode simulation (no qubit limit)~n"),
   format("  gsim('path/filename.clp', Options)  Grover with options~n~n"),
   format("  EVAL/GSIM File types: .clp only ~n~n"),   
   format("  qsim('path/filename.type')           run with defaults~n"),
   format("  qsim('path/filename.type', Options)  run with options~n~n"),
   format("  QSIM File types: .clp  .qbo  .qasm ~n~n"),
   format("  qsim_run(\"file.qasm\", [shots(N)])   simulate any QASM 3 file~n~n"),
   format("  Options:~n"),
   format("    shots(N)          samples          [1000]~n"),
   format("    p(N)              QAOA layers      [1]~n"),
   format("    gamma([...])      cost angles      [[0.5]]~n"),
   format("    beta([...])       mixer angles     [[0.3]]~n"),
   format("    top(N)            top results      [5]~n"),
   format("    amplitudes(true)  show amplitudes~n"),
   format("    outfile(Path)     save QASM here~n~n"),
   format("  e.g. qsim('tests/factor21.clp',[shots(2000),top(5),p(3),gamma([0.2, 0.5, 0.8]),beta([0.8, 0.5, 0.2])]).~n"),      
   sv_limit(L), 
   format("  SV limit: ~w qubits~n", [L]),
   format("~`=t~60|~n~n").
