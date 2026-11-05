problem_spec([
    fd_domain(s0, 0, 1),
    fd_domain(s1, 0, 1),
    fd_domain(s2, 0, 1),
    
    % Enforce the logic constraints using XOR primitives
    fd_eq(s0, 1),
    fd_xor(s0, s1, 0),
    fd_xor(s1, s2, 1)
]).