% =============================================================================
% main3.pl -- test driver for qpcl_qubo
% =============================================================================
% exec3(+FileName) compiles FileName to a QUBO, writes <stem>.qbo,
% anneals it (multiple restarts), and prints the decoded assignment together
% with the QUBO energy and a one-hot validity check.
% =============================================================================
:- use_module(qclp_qubo).
:- use_module(qclp_qubo_sa).

exec3(FileName) :-
    exec3(FileName, []).

exec3(FileName, Options) :-
    format("~n=== ~w ===~n", [FileName]),
    compile_qubo(FileName, Options, Result),
    Result = qubo(Const,Lin,Quad)-VarTable-NBits,
    length(Lin, NLin), length(Quad, NQuad),
    format("  ~w binary variables, ~w linear terms, ~w quadratic terms, constant=~w~n",
           [NBits, NLin, NQuad, Const]),
    file_name_extension(Stem, _, FileName),
    atom_concat(Stem, '.qbo', OutFile),
    qubo_write(Result, OutFile, FileName),
    format("  wrote ~w~n", [OutFile]),
    option_default(restarts, Options, 10, Restarts),
    option_default(iterations, Options, 6000, Iters),
    qubo_blocks(VarTable, Blocks),
    qubo_multi_anneal(qubo(Const,Lin,Quad), NBits, [iterations(Iters),blocks(Blocks)], Restarts, Bits-E),
    ( qubo_valid(VarTable,Bits) -> Valid = valid ; Valid = invalid ),
    qubo_decode(VarTable, Bits, Assign),
    format("  SA result: energy=~w (~w)~n  assignment: ~w~n", [E, Valid, Assign]).

option_default(Key, Options, Default, Value) :-
    Opt =.. [Key, V],
    ( member(Opt, Options) -> Value = V ; Value = Default ).

:- format("~nCLP loaded.  Type  exec3('filename').~n").