// QAOA circuit generated from tests/test1.qbo
// 3 qubits, 3 linear (Z) terms, 3 quadratic (ZZ) terms per layer
// Ising constant offset (not part of circuit): 17.500000
OPENQASM 3.0;
include "stdgates.inc";

// exp(-i*theta*Z_a*Z_b)
gate rzz(theta) a, b {
  cx a, b;
  rz(theta) b;
  cx a, b;
}

// Variable table (index : QPCL key = value)
//   2 : w = 10
//   1 : w = 5
//   0 : w = 0

qubit[3] q;
bit[3] c;

// initial state: equal superposition
h q[0];
h q[1];
h q[2];

// ===== QAOA layer (gamma=0.500000, beta=0.300000) =====
// --- cost unitary U_C(gamma) = exp(-i*gamma*H_Ising) ---
rz(-8.000000) q[0];
rz(-6.500000) q[1];
rz(-8.000000) q[2];
rzz(8.000000) q[0], q[1];
rzz(8.000000) q[0], q[2];
rzz(8.000000) q[1], q[2];

// --- mixer unitary U_B(beta) = exp(-i*beta*sum X_i) ---
rx(0.600000) q[0];
rx(0.600000) q[1];
rx(0.600000) q[2];

// measurement
c[0] = measure q[0];
c[1] = measure q[1];
c[2] = measure q[2];
