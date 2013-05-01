local dirOfThisFile = (...):match("(.-)[^%.]+$")

local util = require(dirOfThisFile .. "util")

module(..., package.seeall)


-- Variables generated by ERPs
local RandomVariableRecord = {}

function RandomVariableRecord:new(name, erp, params, val, logprob, structural, conditioned)
	conditioned = (conditioned == nil) and false or conditioned
	local newobj = { name = name, erp = erp, params = params, val = val, logprob = logprob,
			   active = true, structural = structural, conditioned = conditioned }
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function RandomVariableRecord:copy()
	return RandomVariableRecord:new(self.name, self.erp, self.params, self.val, self.logprob,
									self.structural, self.conditioned)
end


-- Execution trace generated by a probabilistic program.
-- Tracks the random choices made and accumulates probabilities
local RandomExecutionTrace = {}

function RandomExecutionTrace:new(computation, doRejectionInit)
	doRejectionInit = (doRejectionInit == nil) and true or doRejectionInit
	local newobj = {
		computation = computation,
		vars = {},
		varlist = {},
		currVarIndex = 1,
		logprob = 0.0,
		newlogprob = 0.0,
		oldlogprob = 0.0,
		rootframe = nil,
		loopcounters = {},
		conditionsSatisfied = false,
		returnValue = nil
	}
	setmetatable(newobj, self)
	self.__index = self

	if doRejectionInit then
		while not newobj.conditionsSatisfied do
			util.cleartable(newobj.vars)
			newobj:traceUpdate()
		end
	end

	return newobj
end

function RandomExecutionTrace:deepcopy()
	local newdb = RandomExecutionTrace:new(self.computation, false)
	newdb.logprob = self.logprob
	newdb.oldlogprob = self.oldlogprob
	newdb.newlogprob = self.newlogprob
	newdb.conditionsSatisfied = self.conditionsSatisfied
	newdb.returnValue = self.returnValue

	for i,v in ipairs(self.varlist) do
		local newv = v:copy()
		newdb.varlist[i] = newv
		newdb.vars[v.name] = newv
	end

	return newdb
end

function RandomExecutionTrace:freeVarNames(structural, nonstructural)
	structural = (structural == nil) and true or structural
	nonstructural = (nonstructural == nil) and true or nonstructural
	return util.keys(
		util.filter(
			function(rec)
				return not rec.conditioned and
						((structural and rec.structural) or
						(nonstructural and not rec.structural))
			end,
			self.vars))
end

-- Names of variables that this trace has that the other does not
function RandomExecutionTrace:varDiff(other)
	local tbl = {}
	for k,v in pairs(self.vars) do
		if not other.vars[k] then
			table.insert(tbl, k)
		end
	end
	return tbl
end

-- Difference in log probability between this trace and the other
-- due to variables that this one has that the other does not
function RandomExecutionTrace:lpDiff(other)
	return util.sum(
		util.map(
			function(name) return self.vars[name].logprob end,
			self:varDiff(other)))
end

-- The singleton trace object
local trace = nil

-- Run computation and update this trace accordingly
function RandomExecutionTrace:traceUpdate(structureIsFixed)

	local origtrace = trace
	trace = self

	self.logprob = 0.0
	self.newlogprob = 0.0
	util.cleartable(self.loopcounters)
	self.conditionsSatisfied = true
	self.currVarIndex = 1

	-- If updating this trace can change the variable structure, then we
	-- clear out the flat list of variables beforehand
	if not structureIsFixed then
		util.cleartable(self.varlist)
	end

	-- Mark all variables as inactive; only those reached
	-- by the computation will become 'active'
	for name,rec in pairs(self.vars) do
		rec.active = false
	end

	-- Mark that this is the 'root' frame of the current execution trace
	self.rootframe = debug.getinfo(1, 'p').fnprotoid

	-- Run the computation, which will create/lookup random variables
	-- NOTE: Turning the JIT off like this is definitely safe (interpreter
	--	stack will be preserved where we need it), but it may be overly
	--  conservative (we may be able to turn the JIT back on at some parts...) 
	jit.off()
	self.returnValue = self.computation()
	jit.on()

	-- Clean up
	self.rootframe = nil
	util.cleartable(self.loopcounters)

	-- Clear out any random values that are no longer reachable
	self.oldlogprob = 0.0
	for name,rec in pairs(self.vars) do
		if not rec.active then
			self.oldlogprob = self.oldlogprob + rec.logprob
			self.vars[name] = nil
		end
	end

	-- Reset the singleton trace
	trace = origtrace
end

-- Propose a random change to a random variable 'varname'
-- Returns a new sample trace from the computation and the
-- forward and reverse probabilities of this proposal
function RandomExecutionTrace:proposeChange(varname, structureIsFixed)
	local nextTrace = self:deepcopy()
	local var = nextTrace:getRecord(varname)
	local propval = var.erp:proposal(var.val, var.params)
	local fwdPropLP = var.erp:logProposalProb(var.val, propval, var.params)
	local rvsPropLP = var.erp:logProposalProb(propval, var.val, var.params)
	var.val = propval
	var.logprob = var.erp:logprob(var.val, var.params)
	nextTrace:traceUpdate(structureIsFixed)
	fwdPropLP = fwdPropLP + nextTrace.newlogprob
	rvsPropLP = rvsPropLP + nextTrace.oldlogprob
	return nextTrace, fwdPropLP, rvsPropLP
end

-- Return the current structural name, as determined by the interpreter stack
function RandomExecutionTrace:currentName(numFrameSkip)
	
	-- Get list of frames from the root frame to the current frame
	local i = 2 + numFrameSkip
	local flst = {}
	local f = nil
	repeat
		f = debug.getinfo(i, 'p')
		table.insert(flst, 1, f)
		i = i + 1
	until not f or (self.rootframe and f.fnprotoid == self.rootframe)

	-- Build up name string, checking loop counters along the way
	local name = ""
	for i=1,table.getn(flst)-1 do
		f = flst[i]
		name = string.format("%s%d:%d", name, f.fnprotoid, f.bytecodepos)
		local loopnum = self.loopcounters[name] or 0
		name = string.format("%s:%d|", name, loopnum)
	end
	-- For the last (topmost frame), also increment the loop counter
	f = flst[table.getn(flst)]
	name = string.format("%s%d:%d", name, f.fnprotoid, f.bytecodepos)
	local loopnum = self.loopcounters[name] or 0
	self.loopcounters[name] = loopnum + 1
	name = string.format("%s:%d|", name, loopnum)

	return name
end

-- Looks up the value of a random variable.
-- Creates the variable if it does not already exist
function RandomExecutionTrace:lookup(erp, params, numFrameSkip, isStructural, conditionedValue)

	local record = nil
	local name = nil
	-- Try to find the variable (first check the flat list, then do slower name lookup)
	local varIsInFlatList = self.currVarIndex <= table.getn(self.varlist)
	if varIsInFlatList then
		record = self.varlist[self.currVarIndex]
	else
		name = self:currentName(numFrameSkip+1)
		record = self.vars[name]
		if not record or record.erp ~= erp or isStructural ~= record.structural then
			record = nil
		end
	end
	-- If we didn't find the variable, create a new one
	if not record then
		local val = conditionedValue or erp:sample_impl(params)
		local ll = erp:logprob(val, params)
		self.newlogprob  = self.newlogprob + ll
		record = RandomVariableRecord:new(name, erp, params, val, ll, isStructural, conditionedValue ~= nil)
		self.vars[name] = record
	-- Otherwise, reuse the variable we found, but check if its parameters/conditioning
	-- status have changed
	else
		record.conditioned = (conditionedValue ~= nil)
		hasChanges = false
		if not util.arrayequals(record.params, params) then
			record.params = params
			hasChanges = true
		end
		if conditionedValue and conditionedValue ~= record.val then
			record.val = conditionedValue
			record.conditioned = true
			hasChanges = true
		end
		if hasChanges then
			record.logprob = erp:logprob(record.val, params)
		end
	end
	-- Finish up and return
	if not varIsInFlatList then
		table.insert(self.varlist, record)
	end
	self.currVarIndex = self.currVarIndex + 1
	self.logprob = self.logprob + record.logprob
	record.active = true
	return record.val
end

-- Simply retrieve the variable record associated with 'name'
function RandomExecutionTrace:getRecord(name)
	return self.vars[name]
end

-- Add a new factor into the log-likelihood of this trace
function RandomExecutionTrace:addFactor(num)
	self.logprob = self.logprob + num
end

-- Condition the trace on the value of a boolean expression
function RandomExecutionTrace:conditionOn(boolexpr)
	self.conditionsSatisfied = self.conditionsSatisfied and boolexpr
end



-- Exported functions for interacting with the singleton trace

function lookupVariableValue(erp, params, isStructural, numFrameSkip, conditionedValue)
	if not trace then
		return conditionedValue or erp:sample_impl(params)
	else
		-- We don't do numFrameSkip + 1 because this is a tail call
		return trace:lookup(erp, params, numFrameSkip, isStructural, conditionedValue)
	end
end

function newTrace(computation)
	return RandomExecutionTrace:new(computation)
end

function factor(num)
	if trace then
		trace:addFactor(num)
	end
end

function condition(boolexpr)
	if trace then
		trace:conditionOn(boolexpr)
	end
end