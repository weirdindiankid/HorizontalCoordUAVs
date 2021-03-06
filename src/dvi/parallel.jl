# implements a multi-core, single machine parallel value iteration solver

type ParallelSolver <: Solver

    numProcessors::Int64 # number of processors to use
 
    stateOrder::Vector # order for processing chunks at each iter, e.g. [[1,1000],[1000,2000]]  

    maxIteratons::Int64 # number of iterations

    tolerance::Float64 # Bellman residual

    gaussSeidel::Bool # flag for gauss-seidel value iteration (regular uses x2 more memory)

    includeV::Bool # flag for including the utility array

    includeQ::Bool # flag for including the Q-matrix

    includeA::Bool # flag for including the policy
 
end


# over-loaded constructor
function ParallelSolver(numProcessors::Int64; stateOrder::Vector=[], maxIterations::Int64=1000,
                        tolerance::Float64=1e-3, gaussSiedel::Bool=true,
                        includeV::Bool=true, includeQ::Bool=true, includeA::Bool=true)
    return ParallelSolver(numProcessors, stateOrder, maxIterations, tolerance, gaussSiedel, includeV, includeQ, includeA)     
end


# returns the utility function and the Q-matrix
function solve(solver::ParallelSolver, mdp::DiscreteMDP; verbose::Bool=false)
    nProcs   = solver.numProcessors
    maxProcs = round(Int,(CPU_CORES / 2))

    # processor restriction checks
    nProcs < 2 ? error("Less than 2 processors not allowed") : nothing
    nProcs > maxProcs ? error("Number of requested processors is too large, try $maxProcs") : nothing

    # check if a default state ordering is needed
    order = solver.stateOrder
    if isempty(order)
        nStates = numStates(mdp)
        solver.stateOrder = Any[1:nStates]
    end

    gs = solver.gaussSeidel
    u = []
    q = []

    # check gauss-seidel flag
    if gs
        u, q = solveGS(solver, mdp, verbose=verbose)
    else
        u, q = solveRegular(solver, mdp, verbose=verbose)
    end

    p = []

    # check policy flag
    if solver.includeA
        p = computePolicy(mdp, u)
    end

    policy = DiscretePolicy(V=u, Q=q, P=p)

    return policy 
end


function solveGS(solver::ParallelSolver, mdp::DiscreteMDP; verbose::Bool=false)
    
    nStates  = numStates(mdp)
    nActions = numActions(mdp)

    maxIter = solver.maxIteratons
    tol     = solver.tolerance

    nProcs  = solver.numProcessors

    # number of chunks in each DP iteration
    nChunks = length(solver.stateOrder)
    order   = solver.stateOrder

    # shared utility function and Q-matrix
    util = SharedArray(Float64, (nStates), init = S -> S[localindexes(S)] = 0.0, pids = [1:nProcs])
    valQ  = SharedArray(Float64, (nActions, nStates), init = S -> S[localindexes(S)] = 0.0, pids = [1:nProcs])

    iterTime  = 0.0
    totalTime = 0.0

    for i = 1:maxIter
        
        tic()
        residual = 0.0
        
        for c = 1:nChunks
            
            lst = segment(nProcs, order[c])

            results = pmap(x -> (idxs = x; solveChunk(mdp, util, valQ, idxs)), lst)
            
            newResidual = maximum(results)
            newResidual > residual ? (residual = newResidual) : (nothing)

        end # chunk loop 

        iterTime = toq();
        totalTime += iterTime
        verbose ? (@printf("Iter %i: resid = %.3e, runtime = %.3e, net runtime = %.3e\n", i, residual, iterTime, totalTime)) : nothing

        # terminate if tolerance value is reached
        if residual < tol; break; end

    end # main iteration loop

    return util, valQ

end


function solveRegular(solver::ParallelSolver, mdp::DiscreteMDP; verbose::Bool=false)
    
    nStates  = numStates(mdp)
    nActions = numActions(mdp)

    maxIter = solver.maxIteratons
    tol     = solver.tolerance

    nProcs  = solver.numProcessors

    # number of chunks in each DP iteration
    nChunks = length(solver.stateOrder)
    order   = solver.stateOrder

    # shared utility function and Q-matrix
    util1 = SharedArray(Float64, (nStates), init = S -> S[localindexes(S)] = 0.0, pids = collect(1:nProcs))
    util2 = SharedArray(Float64, (nStates), init = S -> S[localindexes(S)] = 0.0, pids = collect(1:nProcs))
    valQ  = SharedArray(Float64, (nActions, nStates), init = S -> S[localindexes(S)] = 0.0, pids = collect(1:nProcs))

    iterTime  = 0.0
    totalTime = 0.0

    uCount = 0
    lastIdx = 1
    for i = 1:maxIter
        # residual tolerance
        residual = 0.0
        uIdx = 1
        tic()
        for c = 1:nChunks
            # util array to update: 1 or 2
            uIdx = uCount % 2 + 1
            lst = segment(nProcs, order[c])

            if uIdx == 1
                # returns the residual
                results = pmap(x -> (idxs = x; solveChunk(mdp, util1, util2, valQ, idxs)), lst)
                newResidual = maximum(results) 
                newResidual > residual ? (residual = newResidual) : (nothing) 
                # update the old utility array in parallel
                results = pmap(x -> (idxs = x; updateChunk(util1, util2, idxs)), lst)
            else
                # returns the residual
                results = pmap(x -> (idxs = x; solveChunk(mdp, util2, util1, valQ, idxs)), lst)
                newResidual = maximum(results) 
                newResidual > residual ? (residual = newResidual) : (nothing) 
                # update the old utility array, this is computationally costly 
                results = pmap(x -> (idxs = x; updateChunk(util2, util1, idxs)), lst)
            end

            uCount += 1
        end # chunk loop 

        iterTime = toq();
        totalTime += iterTime
        verbose ? (@printf("Iter %i: resid = %.3e, runtime = %.3e, net runtime = %.3e\n", i, residual, iterTime, totalTime)) : nothing

        # terminate if tolerance value is reached
        if residual < tol; lastIdx = uIdx; break; end

    end # main iteration loop
    lastIdx == 1 ? (return util2, valQ) : (return util1, valQ)
end


# updates the shared array utility and returns the residual
# valOld is used to update, and valNew is the updated value function
function solveChunk(mdp::DiscreteMDP, valOld::SharedArray, valNew::SharedArray, valQ::SharedArray, iter::UnitRange)

    nActions = numActions(mdp)
    residual = 0.0

    for si = iter

        qHi = -Inf

        for ai = 1:nActions
            
            states, probs = nextStates(mdp, si, ai)
            qNow = reward(mdp, si, ai)

            for sp = 1:length(states)
                spi = states[sp]
                qNow += 0.95 * probs[sp] * valOld[spi]  # gamma = 0.95
            end # sp loop
            
            valQ[ai, si] = qNow
            
            if ai == 1 || qNow > qHi
                qHi = qNow
                valNew[si] = qHi
            end

        end # action loop
        
        newResidual = (valOld[si] - valNew[si])^2
        newResidual > residual ? (residual = newResidual) : (nothing)

    end # state loop
    return residual 
end


# updates shared utility and Q-Matrix for gauss-seidel value iteration
function solveChunk(mdp::DiscreteMDP, util::SharedArray, valQ::SharedArray, iter::UnitRange)

    nActions = numActions(mdp)
    residual = 0.0

    for si = iter

        qHi = -Inf
        utilOld = util[si]
        utilNew = utilOld

        for ai = 1:nActions

            states, probs = nextStates(mdp, si, ai)
            qNow = reward(mdp, si, ai)

            for sp = 1:length(states)
                spi = states[sp]
                qNow += 0.95 * probs[sp] * util[spi]  # gamma = 0.95
            end # sp loop

            valQ[ai, si] = qNow

            if ai == 1 || qNow > qHi
                
                qHi = qNow
                util[si] = qHi

                utilNew = qHi

            end

        end # action loop

        newResidual = (utilOld - utilNew)^2
        newResidual > residual ? (residual = newResidual) : (nothing)

    end # state loop

    return residual

end


# for updating the utility array in parallel
function updateChunk(utilOld::SharedArray, utilNew::SharedArray, iter::UnitRange)
    for i = iter
        utilOld[i] = utilNew[i]
    end
    return iter
end


