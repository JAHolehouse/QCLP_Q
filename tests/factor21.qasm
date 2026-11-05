// QAOA circuit generated from tests/factor21.qbo
// 8 qubits, 8 linear (Z) terms, 27 quadratic (ZZ) terms per layer
// Ising constant offset (not part of circuit): 316.000000
OPENQASM 3.0;
include "stdgates.inc";

// exp(-i*theta*Z_a*Z_b)
gate rzz(theta) a, b {
  cx a, b;
  rz(theta) b;
  cx a, b;
}

// Variable table (index : QPCL key = value)
//   2 : a = 4
//   1 : a = 3
//   0 : a = 2
//   7 : b = 10
//   6 : b = 9
//   5 : b = 8
//   4 : b = 7
//   3 : b = 6

qubit[8] q;
bit[8] c;

// initial state: equal superposition
h q[0];
h q[1];
h q[2];
h q[3];
h q[4];
h q[5];
h q[6];
h q[7];

// ===== QAOA layer (gamma=0.200000, beta=0.800000) =====
// --- cost unitary U_C(gamma) = exp(-i*gamma*H_Ising) ---
rz(-16.800000) q[0];
rz(-16.000000) q[1];
rz(-16.800000) q[2];
rz(-40.800000) q[3];
rz(-40.000000) q[4];
rz(-40.800000) q[5];
rz(-40.800000) q[6];
rz(-40.800000) q[7];
rzz(12.800000) q[0], q[1];
rzz(12.800000) q[0], q[2];
rzz(0.800000) q[0], q[3];
rzz(0.800000) q[0], q[4];
rzz(0.800000) q[0], q[5];
rzz(0.800000) q[0], q[6];
rzz(0.800000) q[0], q[7];
rzz(12.800000) q[1], q[2];
rzz(0.800000) q[1], q[3];
rzz(0.800000) q[1], q[5];
rzz(0.800000) q[1], q[6];
rzz(0.800000) q[1], q[7];
rzz(0.800000) q[2], q[3];
rzz(0.800000) q[2], q[4];
rzz(0.800000) q[2], q[5];
rzz(0.800000) q[2], q[6];
rzz(0.800000) q[2], q[7];
rzz(12.800000) q[3], q[4];
rzz(12.800000) q[3], q[5];
rzz(12.800000) q[3], q[6];
rzz(12.800000) q[3], q[7];
rzz(12.800000) q[4], q[5];
rzz(12.800000) q[4], q[6];
rzz(12.800000) q[4], q[7];
rzz(12.800000) q[5], q[6];
rzz(12.800000) q[5], q[7];
rzz(12.800000) q[6], q[7];

// --- mixer unitary U_B(beta) = exp(-i*beta*sum X_i) ---
rx(1.600000) q[0];
rx(1.600000) q[1];
rx(1.600000) q[2];
rx(1.600000) q[3];
rx(1.600000) q[4];
rx(1.600000) q[5];
rx(1.600000) q[6];
rx(1.600000) q[7];

// ===== QAOA layer (gamma=0.500000, beta=0.500000) =====
// --- cost unitary U_C(gamma) = exp(-i*gamma*H_Ising) ---
rz(-42.000000) q[0];
rz(-40.000000) q[1];
rz(-42.000000) q[2];
rz(-102.000000) q[3];
rz(-100.000000) q[4];
rz(-102.000000) q[5];
rz(-102.000000) q[6];
rz(-102.000000) q[7];
rzz(32.000000) q[0], q[1];
rzz(32.000000) q[0], q[2];
rzz(2.000000) q[0], q[3];
rzz(2.000000) q[0], q[4];
rzz(2.000000) q[0], q[5];
rzz(2.000000) q[0], q[6];
rzz(2.000000) q[0], q[7];
rzz(32.000000) q[1], q[2];
rzz(2.000000) q[1], q[3];
rzz(2.000000) q[1], q[5];
rzz(2.000000) q[1], q[6];
rzz(2.000000) q[1], q[7];
rzz(2.000000) q[2], q[3];
rzz(2.000000) q[2], q[4];
rzz(2.000000) q[2], q[5];
rzz(2.000000) q[2], q[6];
rzz(2.000000) q[2], q[7];
rzz(32.000000) q[3], q[4];
rzz(32.000000) q[3], q[5];
rzz(32.000000) q[3], q[6];
rzz(32.000000) q[3], q[7];
rzz(32.000000) q[4], q[5];
rzz(32.000000) q[4], q[6];
rzz(32.000000) q[4], q[7];
rzz(32.000000) q[5], q[6];
rzz(32.000000) q[5], q[7];
rzz(32.000000) q[6], q[7];

// --- mixer unitary U_B(beta) = exp(-i*beta*sum X_i) ---
rx(1.000000) q[0];
rx(1.000000) q[1];
rx(1.000000) q[2];
rx(1.000000) q[3];
rx(1.000000) q[4];
rx(1.000000) q[5];
rx(1.000000) q[6];
rx(1.000000) q[7];

// ===== QAOA layer (gamma=0.800000, beta=0.200000) =====
// --- cost unitary U_C(gamma) = exp(-i*gamma*H_Ising) ---
rz(-67.200000) q[0];
rz(-64.000000) q[1];
rz(-67.200000) q[2];
rz(-163.200000) q[3];
rz(-160.000000) q[4];
rz(-163.200000) q[5];
rz(-163.200000) q[6];
rz(-163.200000) q[7];
rzz(51.200000) q[0], q[1];
rzz(51.200000) q[0], q[2];
rzz(3.200000) q[0], q[3];
rzz(3.200000) q[0], q[4];
rzz(3.200000) q[0], q[5];
rzz(3.200000) q[0], q[6];
rzz(3.200000) q[0], q[7];
rzz(51.200000) q[1], q[2];
rzz(3.200000) q[1], q[3];
rzz(3.200000) q[1], q[5];
rzz(3.200000) q[1], q[6];
rzz(3.200000) q[1], q[7];
rzz(3.200000) q[2], q[3];
rzz(3.200000) q[2], q[4];
rzz(3.200000) q[2], q[5];
rzz(3.200000) q[2], q[6];
rzz(3.200000) q[2], q[7];
rzz(51.200000) q[3], q[4];
rzz(51.200000) q[3], q[5];
rzz(51.200000) q[3], q[6];
rzz(51.200000) q[3], q[7];
rzz(51.200000) q[4], q[5];
rzz(51.200000) q[4], q[6];
rzz(51.200000) q[4], q[7];
rzz(51.200000) q[5], q[6];
rzz(51.200000) q[5], q[7];
rzz(51.200000) q[6], q[7];

// --- mixer unitary U_B(beta) = exp(-i*beta*sum X_i) ---
rx(0.400000) q[0];
rx(0.400000) q[1];
rx(0.400000) q[2];
rx(0.400000) q[3];
rx(0.400000) q[4];
rx(0.400000) q[5];
rx(0.400000) q[6];
rx(0.400000) q[7];

// measurement
c[0] = measure q[0];
c[1] = measure q[1];
c[2] = measure q[2];
c[3] = measure q[3];
c[4] = measure q[4];
c[5] = measure q[5];
c[6] = measure q[6];
c[7] = measure q[7];
