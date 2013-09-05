
local inf = require("probabilistic.inference")
local util = require("probabilistic.util")

-- Kernel that performs tempered transitions using a 
-- specified annealing schedule.
-- This is a fixed-dimension (non-structure-jumping) kernel
local TemperedTransitionsKernel = {}

-- We inherit some default parameter values from the LARJ kernel

-- 'scheduleGenerator' is a function that takes the current annealing interval and
--    the number of total intervals, and returns a vector of annealing weights
--  This schedule must be symmetric about the midpoint of the annealing sequence
--     in order for the resulting MCMC to be correct.
function TemperedTransitionsKernel:new(innerKernel, annealIntervals, annealStepsPerInterval, scheduleGenerator)
	local newobj = 
	{
		innerKernel = innerKernel,
		annealIntervals = annealIntervals,
		annealStepsPerInterval = annealStepsPerInterval,

		scheduleGenerator = scheduleGenerator,
		currentComputation = nil,
		currentTemps = nil,

		proposalsMade = 0,
		proposalsAccepted = 0,
		annealingProposalsMade = 0,
		annealingProposalsAccepted = 0
	}

	newobj.thunkedComputation = function()
		return newobj.currentComputation(newobj.currentTemps)
	end

	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function TemperedTransitionsKernel:assumeControl(currTrace)
	return currTrace
end

function TemperedTransitionsKernel:next(currState, hyperparams)
	-- If we have no free nonstructural variables, just run the computation and generate
	-- another sample
	local freeVars = currState:freeVarNames(false, true)
	if #freeVars == 0 then
		local newTrace = currState:deepcopy()
		newTrace:traceUpdate()
		return newTrace
	end

	-- -- DEBUG: Tracking energy jumps as a function of annealing step
	-- if not self.energyJumpLog then
	-- 	self.energyJumpLog = {}
	-- 	for i=0,self.annealIntervals-1 do
	-- 		self.energyJumpLog[i] = {}
	-- 	end
	-- end

	-- print("===================")
	-- print("--- INITIAL STATE ---")
	-- for i,v in ipairs(currState.returnValue) do print(v) end

	self.proposalsMade = self.proposalsMade + 1
	local nextTrace = currState:deepcopy()
	nextTrace = self:releaseControl(nextTrace)
	nextTrace = self.innerKernel:assumeControl(nextTrace)
	self.currentComputation = nextTrace.computation
	nextTrace.computation = self.thunkedComputation

	local annealingLpRatio = 0
	local prevNumAnnealPropsMade = self.innerKernel.proposalsMade
	local prevNumAnnealPropsAccepted = self.innerKernel.proposalsAccepted
	for aInterval=0,self.annealIntervals-1 do
		local denomlp = nextTrace.logprob
		self.currentTemps = self.scheduleGenerator(aInterval, self.annealIntervals-1)
		nextTrace:traceUpdate(true)
		local numerlp = nextTrace.logprob
		annealingLpRatio = annealingLpRatio + (numerlp - denomlp)

		-- table.insert(self.energyJumpLog[aInterval], (numerlp - denomlp))

		for aStep=1,self.annealStepsPerInterval do
			nextTrace = self.innerKernel:next(nextTrace)
		end
	end
	self.annealingProposalsMade = self.annealingProposalsMade +
								  self.annealIntervals*self.annealStepsPerInterval
	self.annealingProposalsAccepted = self.annealingProposalsAccepted +
									  (self.innerKernel.proposalsAccepted - prevNumAnnealPropsAccepted)
	self.innerKernel.proposalsMade = prevNumAnnealPropsMade
	self.innerKernel.proposalsAccepted = prevNumAnnealPropsAccepted

	nextTrace.computation = self.currentComputation
	nextTrace = self.innerKernel:releaseControl(nextTrace)
	nextTrace = self:assumeControl(nextTrace)

	-- print("--- FINAL STATE ---")
	-- for i,v in ipairs(nextTrace.returnValue) do print(v) end
	-- print(string.format("Acceptance Prob: %g", annealingLpRatio))

	if nextTrace.conditionsSatisfied and math.log(math.random()) < annealingLpRatio then
		-- print("ACCEPTED")
		self.proposalsAccepted = self.proposalsAccepted + 1
		return nextTrace
	else
		-- print("REJECTED")
		return currState
	end
end

function TemperedTransitionsKernel:releaseControl(currState)
	return currState
end


function TemperedTransitionsKernel:stats()
	if self.proposalsMade > 0 then
		print(string.format("Acceptance ratio: %g (%u/%u)", self.proposalsAccepted/self.proposalsMade,
																	  self.proposalsAccepted, self.proposalsMade))
	end
	if self.annealingProposalsMade > 0 then
		print(string.format("Annealing acceptance ratio: %g (%u/%u)", self.annealingProposalsAccepted/self.annealingProposalsMade,
																	  self.annealingProposalsAccepted, self.annealingProposalsMade))
	end

	-- -- Output the energy jump log
	-- -- local logfile = io.open("energyJumpLog.csv", "w")
	-- -- logfile:write("iter,avgEnergyJump\n")
	-- local logfile = io.open("fullEnergyJumpLog.csv", "w")
	-- logfile:write("iter,energyJump\n")
	-- for i=0,self.annealIntervals-1 do
	-- 	local jumps = self.energyJumpLog[i]
	-- 	for j,v in ipairs(jumps) do
	-- 		logfile:write(string.format("%d,%.8f\n", i+1, v))
	-- 	end
	-- 	-- local avg = util.sumtable(jumps) / #jumps
	-- 	-- logfile:write(string.format("%d,%g\n", i+1, avg))
	-- end
	-- logfile:close()
end


local function TemperedTraceMH(computation, params)
	params = inf.KernelParams:new(params)
	return inf.mcmc(
		computation,
		inf.MultiKernel:new(
			{
				RandomWalkKernel:new(true, true),
				TemperedTransitionsKernel:new(
					RandomWalkKernel:new(false, true),
					params.annealIntervals,
					params.annealStepsPerInterval,
					params.scheduleGenerator
				)
			},
			{"Normal", "Tempered"},
			{1.0-params.temperedTransitionsFreq, params.temperedTransitionsFreq}
		),
		params
	)
end



return 
{
	TemperedTransitionsKernel = TemperedTransitionsKernel,
	TemperedTraceMH = TemperedTraceMH
}








