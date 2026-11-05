// QAOA circuit generated from tests/maxcut.qbo
// 10 qubits, 10 linear (Z) terms, 17 quadratic (ZZ) terms per layer
// Ising constant offset (not part of circuit): 57.000000
OPENQASM 3.0;
include "stdgates.inc";

// exp(-i*theta*Z_a*Z_b)
gate rzz(theta) a, b {
  cx a, b;
  rz(theta) b;
  cx a, b;
}

// Variable table (index : QPCL key = value)
//   1 : v0 = 1
//   0 : v0 = 0
//   3 : v1 = 1
//   2 : v1 = 0
//   5 : v2 = 1
//   4 : v2 = 0
//   7 : v3 = 1
//   6 : v3 = 0
//   9 : v4 = 1
//   8 : v4 = 0

qubit[10] q;
bit[10] c;

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

// ===== QAOA layer (gamma=0.500000, beta=0.300000) =====
// --- cost unitary U_C(gamma) = exp(-i*gamma*H_Ising) ---
rz(-0.500000) q[0];
rz(-0.500000) q[1];
rz(-0.750000) q[2];
rz(-0.750000) q[3];
rz(-0.750000) q[4];
rz(-0.750000) q[5];
rz(-0.500000) q[6];
rz(-0.500000) q[7];
rz(-0.500000) q[8];
rz(-0.500000) q[9];
rzz(12.000000) q[0], q[1];
rzz(0.250000) q[0], q[2];
rzz(0.250000) q[0], q[4];
rzz(0.250000) q[1], q[3];
rzz(0.250000) q[1], q[5];
rzz(12.000000) q[2], q[3];
rzz(0.250000) q[2], q[4];
rzz(0.250000) q[2], q[6];
rzz(0.250000) q[3], q[5];
rzz(0.250000) q[3], q[7];
rzz(12.000000) q[4], q[5];
rzz(0.250000) q[4], q[8];
rzz(0.250000) q[5], q[9];
rzz(12.000000) q[6], q[7];
rzz(0.250000) q[6], q[8];
rzz(0.250000) q[7], q[9];
rzz(12.000000) q[8], q[9];

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
