
local pr = require("probabilistic")
local util = require("probabilistic.util")
local fi = terralib.require("test.freeimage")
local hmc = terralib.require("probabilistic.hmc")
local render = terralib.require("renderer")
local random = require("probabilistic.random")
util.openpackage(pr)


fi.FreeImage_Initialise(0)

----------------------------

local GradientDescentKernel = {}

KernelParams.gdStepSize = 0.001
KernelParams.gdInitialTemp = 1.0
KernelParams.gdFinalTemp= 1.0
KernelParams.gdInitialMass = 1.0
KernelParams.gdFinalMass = 1.0

function GradientDescentKernel:new(stepSize, initTemp, finalTemp, initMass, finalMass, numsamps)
	local newobj = 
	{
		stepSize = stepSize,
		initTemp = initTemp,
		finalTemp = finalTemp,
		initMass = initMass,
		finalMass = finalMass,
		currentIter = 0,
		numIters = numsamps
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function GradientDescentKernel:assumeControl(currTrace)
	self.nonStructs = currTrace:freeVarNames(false, true)
	return currTrace
end

function GradientDescentKernel:releaseControl(currTrace)
	return currTrace
end

function GradientDescentKernel:next(currTrace, hyperparams)

	local alpha = self.currentIter / (self.numIters-1)
	local mass = (1-alpha)*self.initMass + alpha*self.finalMass
	local temp = (1-alpha)*self.initTemp + alpha*self.finalTemp

	local newTrace = currTrace:deepcopy()
	local nonStructs = self.nonStructs
	local indeps = terralib.new(hmc.num[#nonStructs])
	--print("----")
	for i,n in ipairs(nonStructs) do
		local rec = newTrace:getRecord(n)
		local val = rec:getProp("val")
		--print(val)
		local dualval = hmc.makeNum(val)
		rec:setProp("val", dualval)
		indeps[i-1] = dualval
	end
	hmc.toggleLuaAD(true)
	newTrace:flushLogProbs()
	hmc.toggleLuaAD(false)
	local dep = temp * newTrace.logprob
	local gradient = terralib.new(double[#nonStructs])
	hmc.gradient(dep, #nonStructs, indeps, gradient)
	for i,n in ipairs(nonStructs) do
		local rec = newTrace:getRecord(n)
		local currVal = hmc.getValue(rec:getProp("val"))
		local randPart = mass * random.gaussian_sample(0, 1)
		local newVal = currVal + self.stepSize*(randPart + gradient[i-1])
		-- local randPart = rec:getProp("erp"):proposal(currVal, rec:getProp("params"))
		-- local newVal = (1-alpha)*randPart + alpha*(currVal + self.stepSize*gradient[i-1])
		rec:setProp("val", newVal)
	end
	newTrace:flushLogProbs()

	self.currentIter = self.currentIter+1

	-- if math.log(math.random()) < newTrace.logprob - currTrace.logprob then
		return newTrace
	-- else
	-- 	return currTrace
	-- end
end

function GradientDescentKernel:stats()
	-- Does nothing
end

function GradientDescent(computation, params)
	params = KernelParams:new(params)
	return mcmc(computation,
				GradientDescentKernel:new(params.gdStepSize,
										  params.gdInitialTemp,
										  params.gdFinalTemp,
										  params.gdInitialMass,
										  params.gdFinalMass,
										  params.numsamps),
				params)
end

----------------------------

function uniform_falloff_logprob(val, lo, hi)
	local lp = -math.log(hi - lo)
	if val > hi then
		lp = lp - (val-lo)/(hi-lo)
	elseif val < lo then
		lp = lp - (hi-val)/(hi-lo)
	end
	return lp
end

local uniformWithFalloff =
makeERP(random.uniform_sample,
		uniform_falloff_logprob)

----------------------------

local targetMask = render.Framebuffer_newFromMaskImage("test/mask_small.png", 0.0)
render.Framebuffer_invert(targetMask)

local renderbuffer_normal = render.Framebuffer_new(render.Framebuffer_width(targetMask),
												   render.Framebuffer_height(targetMask),
												   0.0)
local renderbuffer_hmc = render.Framebuffer_new(render.Framebuffer_width(targetMask),
												   render.Framebuffer_height(targetMask),
												   hmc.makeNum(0.0))
local minMaxSmoothing = 5
local tightFieldSmoothing = 0.0005
local looseFieldSmoothing = 0.02
-- local tightFieldSmoothing = 0.00025
-- local looseFieldSmoothing = 0.025
local fieldBlend = 0.9
local zeroPixelWeight = 1.0

local function chooseRenderbuffer()
	if hmc.luaADIsOn() then
		return renderbuffer_hmc
	else
		return renderbuffer_normal
	end
end

local function renderCircles(circles, buffer, doSmooth)
	for i,c in ipairs(circles) do
		render.Framebuffer_renderCircle(buffer, c.x, c.y, c.r,
			doSmooth, tightFieldSmoothing, looseFieldSmoothing, fieldBlend, minMaxSmoothing)
	end
end

local function doRender(circles, buffer)
	if hmc.luaADIsOn() then
		renderCircles(circles, buffer, true)
	else
		renderCircles(circles, buffer, false)
	end
end

local function generate(dim)

	-- Params
	local numCircles_poissonLambda = 50
	local pos_min = 0.0
	local pos_max = 1.0
	local radius_min = 0.025
	local radius_max= 0.1
	-- local pos_mean = 0.5
	-- local pos_sd = 0.25
	-- local radius_k = 10.0
	-- local radius_theta = 0.5
	-- local radius_mult = 0.0075
	local constraintTightness = 0.05

	-- Prior
	local numCircles = dim or poisson({numCircles_poissonLambda}, {isStructural=true})
	local circles = {}
	for i=1,numCircles do
		local r = uniformWithFalloff({radius_min, radius_max})
		local x = uniformWithFalloff({pos_min, pos_max})
		local y = uniformWithFalloff({pos_min, pos_max})
		-- local r = radius_mult*gamma({radius_k, radius_theta})
		-- local x = gaussian({pos_mean, pos_sd})
		-- local y = gaussian({pos_mean, pos_sd})
		table.insert(circles, {x=x, y=y, r=r})
	end

	-- Constraint
	if numCircles > 0 then
		local renderbuffer = chooseRenderbuffer()
		render.Framebuffer_clear(renderbuffer)
		doRender(circles, renderbuffer)
		local targetDist = render.Framebuffer_distance(renderbuffer, targetMask, zeroPixelWeight)
		factor(-targetDist/constraintTightness)
	end

	return circles
end

local function makeFixedDimProg(dim)
	return function() return generate(dim) end
end

----------------------------

local verbose = true


math.randomseed(os.time())

local t1 = os.clock()

-- local samps = GradientDescent(makeFixedDimProg(30), {numsamps=1000, gdStepSize=0.00025,
-- 													 gdInitialTemp=1.0, gdFinalTemp=1.0,
-- 													 gdInitialMass=0.0, gdFinalMass=0.0, verbose=verbose})
--local samps = traceMH(makeFixedDimProg(50), {numsamps=500, verbose=verbose})
local samps = LMC(makeFixedDimProg(50), {numsamps=500, partialMomenutmAlpha=0.0, verbose=verbose})
--local samps = HMC(makeFixedDimProg(30), {numsamps=10, numHMCSteps=100, verbose=verbose})
--local samps = LARJLMC(generate, {numsamps=2000, jumpFreq=0.05, annealIntervals=0, annealStepsPerInterval=5, verbose=verbose})
--local samps = T3HMC(generate, {numsamps=1000, jumpFreq=0.05, numT3Steps=50, T3StepSize=0.001, verbose=verbose})
--local samps = LARJDriftMH(generate, {numsamps=2000, jumpFreq=0.05, annealIntervals=0, annealStepsPerInterval=5, defaultBandWidth=0.03, verbose=verbose})
local circles
local finallp
circles, finallp = sampleMAP(samps)

print(string.format("numCircles: %d", #circles))
print(string.format("Final logprob: %g", finallp))
render.Framebuffer_clear(renderbuffer_normal)
renderCircles(circles, renderbuffer_normal, true)
render.Framebuffer_invert(renderbuffer_normal)
render.Framebuffer_saveToPNGImage(renderbuffer_normal, "test/output_smooth.png")
local finalbuffer = render.Framebuffer_new(500, 500, 0.0)
renderCircles(circles, finalbuffer, false)
render.Framebuffer_invert(finalbuffer)
render.Framebuffer_saveToPNGImage(finalbuffer, "test/output.png")

local t2 = os.clock()
print(string.format("Time: %g", t2-t1))

print("Rendering movie of chain dynamics...")	
for i,s in ipairs(samps) do
	io.write(string.format(" frame %d\r", i))
	io.flush()
	render.Framebuffer_clear(renderbuffer_normal)
	renderCircles(s.returnValue, renderbuffer_normal, true)
	render.Framebuffer_invert(renderbuffer_normal)
	render.Framebuffer_saveToPNGImage(renderbuffer_normal, string.format("test/movie_%06d.png", i-1))
end
io.write("\nCompressing movie...")
io.flush()
util.wait("ffmpeg -y -r 5 -i test/movie_%06d.png -c:v libx264 -r 5 -pix_fmt yuv420p test/chain_dynamics.mp4 2>&1")
util.wait("rm -f test/movie_*.png")
print("DONE.")

-- print("Rendering movie of gradients...")
-- for i,s in ipairs(samps) do
-- 	io.write(string.format(" frame %d\r", i))
-- 	io.flush()
-- 	for i,v in ipairs(s.varlist) do
-- 		if not v.structural then v.val = hmc.makeNum(v.val) end
-- 	end
-- 	hmc.toggleLuaAD(true)
-- 	s:flushLogProbs()
-- 	render.Framebuffer_gradientImage(renderbuffer_hmc, renderbuffer_normal, s.logprob)
-- 	hmc.toggleLuaAD(false)
-- 	render.Framebuffer_saveGradientImageToPNGImage(renderbuffer_normal, string.format("test/gradmovie_%06d.png", i-1))
-- 	-- Restore values
-- 	for i,v in ipairs(s.varlist) do
-- 		if not v.structural then v.val = hmc.getValue(v.val) end
-- 	end
-- end
-- io.write("\nCompressing movie...")
-- io.flush()
-- util.wait("ffmpeg -y -r 5 -i test/gradmovie_%06d.png -c:v libx264 -r 5 -pix_fmt yuv420p test/grad_dynamics.mp4 2>&1")
-- util.wait("rm -f test/gradmovie_*.png")
-- print("DONE.")

render.Framebuffer_delete(finalbuffer)
render.Framebuffer_delete(renderbuffer_normal)
render.Framebuffer_delete(renderbuffer_hmc)
render.Framebuffer_delete(targetMask)


----------------------------


-- -- TEST
-- local fb = render.Framebuffer_new(500, 500, 0.0)
-- local circles = {{x=0.4, y=0.5, r=0.1}, {x=0.6, y=0.5, r=0.1}}
-- renderCircles(circles, fb, true, fieldSmoothing, minMaxSmoothing)
-- render.Framebuffer_invert(fb)
-- render.Framebuffer_saveToPNGImage(fb, "test/output_smooth.png")


----------------------------

fi.FreeImage_DeInitialise()





