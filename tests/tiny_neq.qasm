// QAOA circuit generated from tests/tiny_neq.qbo
// 4 qubits, 4 linear (Z) terms, 4 quadratic (ZZ) terms per layer
// Ising constant offset (not part of circuit): 12.000000
OPENQASM 3.0;
include "stdgates.inc";

// exp(-i*theta*Z_a*Z_b)
gate rzz(theta) a, b {
  cx a, b;
  rz(theta) b;
  cx a, b;
}

// Variable table (index : QPCL key = value)
//   1 : x = 1
//   0 : x = 0
//   3 : y = 1
//   2 : y = 0

qubit[4] q;
bit[4] c;

// initial state: equal superposition
h q[0];
h q[1];
h q[2];
h q[3];

// ===== QAOA layer (gamma=0.500000, beta=0.300000) =====
// --- cost unitary U_C(gamma) = exp(-i*gamma*H_Ising) ---
rz(-2.000000) q[0];
rz(-2.000000) q[1];
rz(-2.000000) q[2];
rz(-2.000000) q[3];
rzz(4.000000) q[0], q[1];
rzz(2.000000) q[0], q[2];
rzz(2.000000) q[1], q[3];
rzz(4.000000) q[2], q[3];

// --- mixer unitary U_B(beta) = exp(-i*beta*sum X_i) ---
rx(0.600000) q[0];
rx(0.600000) q[1];
rx(0.600000) q[2];
rx(0.600000) q[3];

// measurement
c[0] = measure q[0];
c[1] = measure q[1];
c[2] = measure q[2];
c[3] = measure q[3];
