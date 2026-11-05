// QAOA circuit generated from tests/prob3_vertex_cover.qbo
// 20 qubits, 20 linear (Z) terms, 24 quadratic (ZZ) terms per layer
// Ising constant offset (not part of circuit): 190.500000
OPENQASM 3.0;
include "stdgates.inc";

// exp(-i*theta*Z_a*Z_b)
gate rzz(theta) a, b {
  cx a, b;
  rz(theta) b;
  cx a, b;
}

// Variable table (index : QPCL key = value)
//   1 : x0 = 1
//   0 : x0 = 0
//   3 : n0 = 1
//   2 : n0 = 0
//   5 : x1 = 1
//   4 : x1 = 0
//   7 : n1 = 1
//   6 : n1 = 0
//   9 : x2 = 1
//   8 : x2 = 0
//   11 : n2 = 1
//   10 : n2 = 0
//   13 : x3 = 1
//   12 : x3 = 0
//   15 : n3 = 1
//   14 : n3 = 0
//   17 : x4 = 1
//   16 : x4 = 0
//   19 : n4 = 1
//   18 : n4 = 0

qubit[20] q;
bit[20] c;

// initial state: equal superposition
h q[0];
h q[1];
h q[2];
h q[3];
h q[4];
h q[5];
h q[6];
h q[7];
h q[8];
h q[9];
h q[10];
h q[11];
h q[12];
h q[13];
h q[14];
h q[15];
h q[16];
h q[17];
h q[18];
h q[19];

// ===== QAOA layer (gamma=0.500000, beta=0.300000) =====
// --- cost unitary U_C(gamma) = exp(-i*gamma*H_Ising) ---
rz(-2.000000) q[0];
rz(-1.500000) q[1];
rz(-2.000000) q[2];
rz(-4.000000) q[3];
rz(-2.000000) q[4];
rz(-1.500000) q[5];
rz(-2.000000) q[6];
rz(-4.000000) q[7];
rz(-2.000000) q[8];
rz(-1.500000) q[9];
rz(-2.000000) q[10];
rz(-6.000000) q[11];
rz(-2.000000) q[12];
rz(-1.500000) q[13];
rz(-2.000000) q[14];
rz(-4.000000) q[15];
rz(-2.000000) q[16];
rz(-1.500000) q[17];
rz(-2.000000) q[18];
rz(-8.000000) q[19];
rzz(16.000000) q[0], q[1];
rzz(2.000000) q[0], q[2];
rzz(2.000000) q[1], q[3];
rzz(16.000000) q[2], q[3];
rzz(2.000000) q[3], q[11];
rzz(16.000000) q[4], q[5];
rzz(2.000000) q[4], q[6];
rzz(2.000000) q[5], q[7];
rzz(16.000000) q[6], q[7];
rzz(2.000000) q[7], q[19];
rzz(16.000000) q[8], q[9];
rzz(2.000000) q[8], q[10];
rzz(2.000000) q[9], q[11];
rzz(16.000000) q[10], q[11];
rzz(2.000000) q[11], q[19];
rzz(16.000000) q[12], q[13];
rzz(2.000000) q[12], q[14];
rzz(2.000000) q[13], q[15];
rzz(16.000000) q[14], q[15];
rzz(2.000000) q[15], q[19];
rzz(16.000000) q[16], q[17];
rzz(2.000000) q[16], q[18];
rzz(2.000000) q[17], q[19];
rzz(16.000000) q[18], q[19];

// --- mixer unitary U_B(beta) = exp(-i*beta*sum X_i) ---
rx(0.600000) q[0];
rx(0.600000) q[1];
rx(0.600000) q[2];
rx(0.600000) q[3];
rx(0.600000) q[4];
rx(0.600000) q[5];
rx(0.600000) q[6];
rx(0.600000) q[7];
rx(0.600000) q[8];
rx(0.600000) q[9];
rx(0.600000) q[10];
rx(0.600000) q[11];
rx(0.600000) q[12];
rx(0.600000) q[13];
rx(0.600000) q[14];
rx(0.600000) q[15];
rx(0.600000) q[16];
rx(0.600000) q[17];
rx(0.600000) q[18];
rx(0.600000) q[19];

// measurement
c[0] = measure q[0];
c[1] = measure q[1];
c[2] = measure q[2];
c[3] = measure q[3];
c[4] = measure q[4];
c[5] = measure q[5];
c[6] = measure q[6];
c[7] = measure q[7];
c[8] = measure q[8];
c[9] = measure q[9];
c[10] = measure q[10];
c[11] = measure q[11];
c[12] = measure q[12];
c[13] = measure q[13];
c[14] = measure q[14];
c[15] = measure q[15];
c[16] = measure q[16];
c[17] = measure q[17];
c[18] = measure q[18];
c[19] = measure q[19];
