%% fd_implies and fd_or in the QUBO (fixed 2 Oct 2026: both failed to
%% encode, even on 0/1 variables). Solutions: every x,y,z in 0/1 with
%% (x = 1 -> y = 0) and (y = 1 or z = 1): (0,0,1) (0,1,0) (0,1,1) (1,0,1).
problem_spec([
    fd_domain(x,0,1), fd_domain(y,0,1), fd_domain(z,0,1),
    fd_implies(fd_eq(x,1), fd_eq(y,0)),
    fd_or(fd_eq(y,1), fd_eq(z,1))
]).
