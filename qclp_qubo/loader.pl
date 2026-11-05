:- module(loader, [
    solve_puzzle/1,
    solve_puzzle/2
]).

:- use_module(qclp_qubo).
:- use_module(qclp_qubo_sa).

option_default(Key, Options, Default, Value) :-
    Opt =.. [Key, V],
    ( member(Opt, Options) -> Value = V ; Value = Default ).

%% ---------------------------------------------------------------------------
%% solve_puzzle(+Module)
%%   Module must already be loaded and must export problem_spec/1.
%%   Usage:
%%       ?- [loader].
%%       ?- ['sudoku4.clp'].  %% actually a module
%%       ?- solve_puzzle(sudoku4).
%% ---------------------------------------------------------------------------
solve_puzzle(Module) :-
    solve_puzzle(Module, []).

solve_puzzle(Module, Options) :-
    format("~n=== Solving puzzle in module ~w ===~n", [Module]),

    % Get the problem specification from the module
    Module:problem_spec(Goals),
    length(Goals, NGoals),
    format("  Loaded problem_spec with ~w goals.~n", [NGoals]),

    % Compile from in-memory goals using only exported predicates
    compile_qubo_from_goals(Goals, Options, Result),
    Result = qubo(Const,Lin,Quad)-VarTable-NBits,

    length(Lin, NLin),
    length(Quad, NQuad),
    format("  QUBO: ~w bits, ~w linear, ~w quadratic, const=~w~n",
           [NBits, NLin, NQuad, Const]),

    % Annealing parameters
    option_default(restarts, Options, 10, Restarts),
    option_default(iterations, Options, 6000, Iters),

    % One-hot block structure
    qubo_blocks(VarTable, Blocks),

    % Run simulated annealing
    qubo_multi_anneal(
        qubo(Const,Lin,Quad),
        NBits,
        [iterations(Iters), blocks(Blocks)],
        Restarts,
        Bits-Energy
    ),

    % Decode and validate
    ( qubo_valid(VarTable, Bits) -> Valid = valid ; Valid = invalid ),
    qubo_decode(VarTable, Bits, Assign),

    format("~n=== Solution ===~n"),
    format("  Energy: ~w (~w)~n", [Energy, Valid]),
    format("  Assignment: ~w~n", [Assign]).

%% ---------------------------------------------------------------------------
%% compile_qubo_from_goals(+Goals, +Options, -Result)
%%   Wrapper around qclp_qubo internals using only exported predicates.
%% ---------------------------------------------------------------------------
compile_qubo_from_goals(Goals, Options, Result) :-
    % Write goals to a temporary file so we can use compile_qubo/3
    tmp_file_stream(text, TmpFile, Stream),
    write(Stream, 'problem_spec('),
    write_term(Stream, Goals, [fullstop(false)]),
    write(Stream, ').'),
    close(Stream),

    compile_qubo(TmpFile, Options, Result),
    delete_file(TmpFile).
