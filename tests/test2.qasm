// QAOA circuit generated from ./tests/test2.qbo
// 13 qubits, 13 linear (Z) terms, 36 quadratic (ZZ) terms per layer
// Ising constant offset (not part of circuit): 548.000000
OPENQASM 3.0;
include "stdgates.inc";

// exp(-i*theta*Z_a*Z_b)
gate rzz(theta) a, b {
  cx a, b;
  rz(theta) b;
  cx a, b;
}

// Variable table (index : QPCL key = value)
//   6 : a = 10
//   5 : a = 7
//   4 : a = 6
//   3 : a = 5
//   2 : a = 3
//   1 : a = 2
//   0 : a = 1
//   12 : b = 5
//   11 : b = 4
//   10 : b = 3
//   9 : b = 2
//   8 : b = 1
//   7 : b = 0

qubit[13] q;
bit[13] c;

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

// ===== QAOA layer (gamma=0.500000, beta=0.300000) =====
// --- cost unitary U_C(gamma) = exp(-i*gamma*H_Ising) ---
rz(-100.000000) q[0];
rz(-100.000000) q[1];
rz(-100.000000) q[2];
rz(-100.000000) q[3];
rz(-100.000000) q[4];
rz(-100.000000) q[5];
rz(-104.000000) q[6];
rz(-80.000000) q[7];
rz(-80.000000) q[8];
rz(-81.000000) q[9];
rz(-81.000000) q[10];
rz(-81.000000) q[11];
rz(-81.000000) q[12];
rzz(20.000000) q[0], q[1];
rzz(20.000000) q[0], q[2];
rzz(20.000000) q[0], q[3];
rzz(20.000000) q[0], q[4];
rzz(20.000000) q[0], q[5];
rzz(20.000000) q[0], q[6];
rzz(20.000000) q[1], q[2];
rzz(20.000000) q[1], q[3];
rzz(20.000000) q[1], q[4];
rzz(20.000000) q[1], q[5];
rzz(20.000000) q[1], q[6];
rzz(20.000000) q[2], q[3];
rzz(20.000000) q[2], q[4];
rzz(20.000000) q[2], q[5];
rzz(20.000000) q[2], q[6];
rzz(20.000000) q[3], q[4];
rzz(20.000000) q[3], q[5];
rzz(20.000000) q[3], q[6];
rzz(20.000000) q[4], q[5];
rzz(20.000000) q[4], q[6];
rzz(20.000000) q[5], q[6];
rzz(20.000000) q[7], q[8];
rzz(20.000000) q[7], q[9];
rzz(20.000000) q[7], q[10];
rzz(20.000000) q[7], q[11];
rzz(20.000000) q[7], q[12];
rzz(20.000000) q[8], q[9];
rzz(20.000000) q[8], q[10];
rzz(20.000000) q[8], q[11];
rzz(20.000000) q[8], q[12];
rzz(20.000000) q[9], q[10];
rzz(20.000000) q[9], q[11];
rzz(20.000000) q[9], q[12];
rzz(20.000000) q[10], q[11];
rzz(20.000000) q[10], q[12];
rzz(20.000000) q[11], q[12];

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
