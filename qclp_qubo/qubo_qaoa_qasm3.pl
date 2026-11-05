% =============================================================================
% qubo_qaoa_qasm3.pl  --  QUBO -> QAOA -> OpenQASM 3.0 compiler
% =============================================================================
% Reads a QUBO file in the format written by qpcl_qubo:qubo_write/3
% (lines "constant C", "linear I C", "quadratic I J C", plus the
% "%   IDX : KEY = VAL" variable-table comments) and emits an OpenQASM 3.0
% QAOA (Quantum Approximate Optimization Algorithm) circuit -- the standard
% way to run a QUBO on a gate-model quantum computer instead of an annealer.
%
% MAPPING (QUBO -> Ising -> circuit)
%   QUBO:  H = c + sum_i a_i x_i + sum_{i<j} b_ij x_i x_j        (x_i in {0,1})
%   Substitute x_i = (1 - z_i)/2  (z_i in {-1,+1}):
%     H = offset + sum_i h_i z_i + sum_{i<j} J_ij z_i z_j
%       h_i    = -a_i/2 - sum_{j: pair (i,j)} b_ij/4
%       J_ij   = b_ij/4
%       offset = c + sum_i a_i/2 + sum_{i<j} b_ij/4   (irrelevant to circuit)
%
%   QAOA circuit, p layers, parameters gamma_k, beta_k:
%     1. H on every qubit               (start in |+>^n)
%     2. cost layer:  rz(2*gamma*h_i) q[i];  rzz(2*gamma*J_ij) q[i],q[j];
%     3. mixer layer: rx(2*beta) q[i];  for every qubit
%     repeat 2-3 for each of the p layers, then measure all qubits.
%
% USAGE (from swipl, same style as exec3/1,2 in main3.pl):
%   ?- [qubo_qaoa_qasm3].
%   ?- qaoa3('queens4_qubo.txt').
%   ?- qaoa3('queens4_qubo.txt',
%            [p(2), gamma([0.6,0.4]), beta([0.3,0.2]),
%             outfile('queens4_qaoa.qasm')]).
%
% gamma/beta are variational QAOA parameters -- pick values, run the
% circuit, evaluate the cost, then re-run with new values from a classical
% optimizer (the usual QAOA loop). Defaults below (gamma=0.5, beta=0.3) are
% just placeholders so the emitted circuit is immediately valid/runnable.
% =============================================================================
:- module(qubo_qaoa_qasm3, [
    qaoa3/1,            % +QuboFile
    qaoa3/2,            % +QuboFile, +Options
    qubo_to_qaoa_qasm3/3 % +QuboFile, +Options, -QasmString
]).

:- use_module(library(assoc)).
:- use_module(library(pairs)).
:- use_module(library(apply)).
:- use_module(library(lists)).

%% ---------------------------------------------------------------------------
%% Option handling
%% ---------------------------------------------------------------------------
option_default(Key, Options, Default, Value) :-
    Opt =.. [Key, V],
    ( member(Opt, Options) -> Value = V ; Value = Default ).

pad_list(List, N, Padded) :-
    length(List, L),
    ( L >= N -> length(Padded0, N), append(Padded0, _, List), Padded = Padded0
    ; last(List, Last),
      Extra is N - L,
      length(ExtraList, Extra),
      maplist(=(Last), ExtraList),
      append(List, ExtraList, Padded)
    ).

%% ---------------------------------------------------------------------------
%% Top level
%% ---------------------------------------------------------------------------
%% qaoa3(+QuboFile)
%%   Default: p=1, gamma=[0.5], beta=[0.3], output = <stem>_qaoa.qasm
qaoa3(QuboFile) :- qaoa3(QuboFile, []).

%% qaoa3(+QuboFile, +Options)
%%   Options:
%%     p(N)          -- number of QAOA layers (default 1)
%%     gamma(List)   -- list of gamma angles, one per layer (default [0.5])
%%     beta(List)    -- list of beta angles, one per layer (default [0.3])
%%     outfile(File) -- output path (default: replace .txt with _qaoa.qasm,
%%                      or append _qaoa.qasm)
qaoa3(QuboFile, Options) :-
    qubo_to_qaoa_qasm3(QuboFile, Options, Qasm),
    default_outfile(QuboFile, Options, OutFile),
    setup_call_cleanup(
        open(OutFile, write, Stream),
        write(Stream, Qasm),
        close(Stream)
    ),
    format("Wrote ~w~n", [OutFile]).

default_outfile(QuboFile, Options, OutFile) :-
    ( member(outfile(OutFile), Options) -> true
    ; ( sub_atom(QuboFile, Before, _, 0, '.txt') ->
          sub_atom(QuboFile, 0, Before, _, Stem)
      ;   Stem = QuboFile
      ),
      atom_concat(Stem, '_qaoa.qasm', OutFile)
    ).

%% qubo_to_qaoa_qasm3(+QuboFile, +Options, -QasmString)
%%   Does the full compile, returning the QASM3 program as a string
%%   (useful for testing without writing a file).
qubo_to_qaoa_qasm3(QuboFile, Options, Qasm) :-
    option_default(p, Options, 1, P),
    option_default(gamma, Options, [0.5], Gammas0),
    option_default(beta, Options, [0.3], Betas0),
    pad_list(Gammas0, P, Gammas),
    pad_list(Betas0, P, Betas),
    parse_qubo_file(QuboFile, Constant, Linear, Quad, VarTable, NBits),
    qubo_to_ising(Constant, Linear, Quad, NBits, Offset, H, J),
    with_output_to(string(Qasm),
        write_qasm3(QuboFile, NBits, Offset, H, J, P, Gammas, Betas, VarTable)).

%% ---------------------------------------------------------------------------
%% Parsing a qpcl_qubo-style QUBO file
%% ---------------------------------------------------------------------------
%% parse_qubo_file(+FilePath, -Constant, -Linear, -Quad, -VarTable, -NBits)
%%   Linear   : list of I-Coeff
%%   Quad     : list of (I-J)-Coeff, I<J
%%   VarTable : list of idx(Idx,Key,Val) from "%   IDX : KEY = VAL" comments
parse_qubo_file(FilePath, Constant, Linear, Quad, VarTable, NBits) :-
    setup_call_cleanup(
        open(FilePath, read, Stream),
        read_qubo_lines(Stream, 0, Constant, Linear, Quad, VarTable, MaxIdx),
        close(Stream)
    ),
    NBits is MaxIdx + 1.

read_qubo_lines(Stream, MaxIn, Constant, Linear, Quad, VarTable, MaxOut) :-
    ( at_end_of_stream(Stream) ->
        Constant = 0, Linear = [], Quad = [], VarTable = [], MaxOut = MaxIn
    ;   read_line_to_string(Stream, Line),
        classify_line(Line, MaxIn, Item, MaxMid),
        read_qubo_lines(Stream, MaxMid, Constant1, Linear1, Quad1, VarTable1, MaxOut),
        ( Item = constant(C)   -> Constant = C, Linear = Linear1, Quad = Quad1, VarTable = VarTable1
        ; Item = linear(I,C)   -> Constant = Constant1, Linear = [I-C|Linear1], Quad = Quad1, VarTable = VarTable1
        ; Item = quadratic(IJ,C) -> Constant = Constant1, Linear = Linear1, Quad = [IJ-C|Quad1], VarTable = VarTable1
        ; Item = vartable(V)   -> Constant = Constant1, Linear = Linear1, Quad = Quad1, VarTable = [V|VarTable1]
        ; /* skip */             Constant = Constant1, Linear = Linear1, Quad = Quad1, VarTable = VarTable1
        )
    ).

%% classify_line(+Line, +MaxIn, -Item, -MaxOut)
classify_line(Line, MaxIn, Item, MaxOut) :-
    split_string(Line, " \t", " \t", Parts0),
    exclude(==(""), Parts0, Parts),
    ( Parts = ["constant", CS] ->
        number_string(C, CS), Item = constant(C), MaxOut = MaxIn
    ; Parts = ["linear", IS, CS] ->
        number_string(I, IS), number_string(C, CS),
        Item = linear(I,C), MaxOut0 is max(MaxIn, I), MaxOut = MaxOut0
    ; Parts = ["quadratic", IS, JS, CS] ->
        number_string(I, IS), number_string(J, JS), number_string(C, CS),
        ( I < J -> IJ = I-J ; IJ = J-I ),
        Item = quadratic(IJ,C),
        MaxOut0 is max(max(MaxIn, I), J), MaxOut = MaxOut0
    ; classify_vartable(Line, V) ->
        Item = vartable(V), MaxOut = MaxIn
    ;   Item = skip, MaxOut = MaxIn
    ).

%% classify_vartable(+Line, -idx(Idx,Key,Val))
%%   Matches lines like "%   3 : Q0 = 3" (but not the "%   3: -8," style
%%   dimod-dict lines, which contain no " = ").
classify_vartable(Line, idx(Idx,Key,Val)) :-
    string_concat("%", Rest0, Line),
    split_string(Rest0, ":", "", [IdxStr, Rest1]),
    split_string(Rest1, "=", "", [KeyStr, ValStr]),
    split_string(IdxStr, " \t", " \t", [IdxTrim]),
    IdxTrim \== "",
    number_string(Idx, IdxTrim),
    split_string(KeyStr, " \t", " \t", [Key0]),
    split_string(ValStr, " \t", " \t", [ValStr1]),
    ( ValStr1 == "" -> Val = "" ; Val = ValStr1 ),
    Key = Key0.

%% ---------------------------------------------------------------------------
%% QUBO -> Ising
%% ---------------------------------------------------------------------------
%% qubo_to_ising(+Constant, +Linear, +Quad, +NBits, -Offset, -H, -J)
%%   H : sorted list of I-Hi   (only non-zero terms)
%%   J : sorted list of (I-J)-Jij (only non-zero terms)
qubo_to_ising(Constant, Linear, Quad, _NBits, Offset, H, J) :-
    empty_assoc(H0), empty_assoc(J0),
    foldl(linear_to_ising, Linear, Constant-H0, Offset1-H1),
    foldl(quad_to_ising, Quad, Offset1-H1-J0, Offset-H2-J1),
    assoc_to_list(H2, HPairs0),
    exclude(near_zero, HPairs0, H),
    assoc_to_list(J1, JPairs0),
    exclude(near_zero, JPairs0, J).

near_zero(_-V) :- abs(V) < 1.0e-9.

linear_to_ising(I-A, OffIn-HIn, OffOut-HOut) :-
    OffOut is OffIn + A/2,
    add_to_assoc(HIn, I, -A/2, HOut).

quad_to_ising((I-J)-B, OffIn-HIn-JIn, OffOut-HOut-JOut) :-
    OffOut is OffIn + B/4,
    add_to_assoc(HIn, I, -B/4, HMid),
    add_to_assoc(HMid, J, -B/4, HOut),
    add_to_assoc(JIn, I-J, B/4, JOut).

%% add_to_assoc(+AssocIn, +Key, +Delta, -AssocOut)
add_to_assoc(AssocIn, Key, Delta, AssocOut) :-
    ( get_assoc(Key, AssocIn, Old) -> New is Old + Delta ; New = Delta ),
    put_assoc(Key, AssocIn, New, AssocOut).

%% ---------------------------------------------------------------------------
%% QASM3 emission
%% ---------------------------------------------------------------------------
write_qasm3(QuboFile, NBits, Offset, H, J, P, Gammas, Betas, VarTable) :-
    length(H, NLin), length(J, NQuad),
    format("// QAOA circuit generated from ~w~n", [QuboFile]),
    format("// ~w qubits, ~w linear (Z) terms, ~w quadratic (ZZ) terms per layer~n", [NBits, NLin, NQuad]),
    format("// Ising constant offset (not part of circuit): ~6f~n", [Offset]),
    format("OPENQASM 3.0;~n", []),
    format("include \"stdgates.inc\";~n~n", []),
    format("// exp(-i*theta*Z_a*Z_b)~n", []),
    format("gate rzz(theta) a, b {~n", []),
    format("  cx a, b;~n", []),
    format("  rz(theta) b;~n", []),
    format("  cx a, b;~n", []),
    format("}~n~n", []),
    write_vartable(VarTable),
    format("qubit[~w] q;~n", [NBits]),
    format("bit[~w] c;~n~n", [NBits]),
    format("// initial state: equal superposition~n", []),
    write_h_layer(NBits),
    format("~n", []),
    write_layers(P, Gammas, Betas, H, J, NBits),
    format("// measurement~n", []),
    write_measurements(NBits).

write_vartable([]) :- !.
write_vartable(VarTable) :-
    format("// Variable table (index : QPCL key = value)~n", []),
    forall(member(idx(Idx,Key,Val), VarTable),
           format("//   ~w : ~w = ~w~n", [Idx,Key,Val])),
    format("~n", []).

write_h_layer(NBits) :-
    NMax is NBits - 1,
    forall(between(0, NMax, I), format("h q[~w];~n", [I])).

write_measurements(NBits) :-
    NMax is NBits - 1,
    forall(between(0, NMax, I), format("c[~w] = measure q[~w];~n", [I,I])).

write_layers(0, _, _, _, _, _) :- !.
write_layers(P, [Gamma|Gammas], [Beta|Betas], H, J, NBits) :-
    P > 0,
    format("// ===== QAOA layer (gamma=~6f, beta=~6f) =====~n", [Gamma, Beta]),
    format("// --- cost unitary U_C(gamma) = exp(-i*gamma*H_Ising) ---~n", []),
    forall(member(I-Hi, H),
           ( Angle is 2*Gamma*Hi, format("rz(~6f) q[~w];~n", [Angle, I]) )),
    forall(member((I-Jx)-Jij, J),
           ( Angle is 2*Gamma*Jij, format("rzz(~6f) q[~w], q[~w];~n", [Angle, I, Jx]) )),
    format("~n", []),
    format("// --- mixer unitary U_B(beta) = exp(-i*beta*sum X_i) ---~n", []),
    Angle2 is 2*Beta,
    ( NBits > 0 -> NMax is NBits - 1, forall(between(0, NMax, I2), format("rx(~6f) q[~w];~n", [Angle2, I2])) ; true ),
    format("~n", []),
    P1 is P - 1,
    write_layers(P1, Gammas, Betas, H, J, NBits).
