
local pr = require("probabilistic")
local util = require("probabilistic.util")
local fi = terralib.require("test.freeimage")
local hmc = terralib.require("probabilistic.hmc")
local render = terralib.require("renderer")
util.openpackage(pr)


fi.FreeImage_Initialise(0)

----------------------------

local targetMask = render.Framebuffer_newFromMaskImage("test/mask_small.png", 0.0)
render.Framebuffer_invert(targetMask)

local renderbuffer_normal = render.Framebuffer_new(render.Framebuffer_width(targetMask),
												   render.Framebuffer_height(targetMask),
												   0.0)
local renderbuffer_hmc = render.Framebuffer_new(render.Framebuffer_width(targetMask),
												   render.Framebuffer_height(targetMask),
												   hmc.makeNum(0.0))
local minMaxSmoothing = 200
--local fieldSmoothing = 0.0025
local fieldSmoothing = 0.005

local function chooseRenderbuffer()
	if hmc.luaADIsOn() then
		return renderbuffer_hmc
	else
		return renderbuffer_normal
	end
end

local function renderCircles(circles, buffer, doSmooth, fieldSmooth, mmSmooth)
	for i,c in ipairs(circles) do
		render.Framebuffer_renderCircle(buffer, c.x, c.y, c.r, doSmooth, fieldSmooth, mmSmooth)
	end
end

local function generate()

	-- Params
	local numCircles_poissonLambda = 40
	local pos_min = 0.0
	local pos_max = 1.0
	local radius_min = 0.005
	local radius_max = 0.05
	local constraintTightness = 0.1

	-- Prior, plus rendering as we go
	local numCircles = poisson({numCircles_poissonLambda}, {isStructural=true})
	local circles = {}
	for i=1,numCircles do
		local r = uniform({radius_min, radius_max})
		local x = uniform({pos_min, pos_max})
		local y = uniform({pos_min, pos_max})
		table.insert(circles, {x=x, y=y, r=r})
	end

	-- Constraint
	if numCircles > 0 then
		local renderbuffer = chooseRenderbuffer()
		render.Framebuffer_clear(renderbuffer)
		renderCircles(circles, renderbuffer, true, fieldSmoothing, minMaxSmoothing)
		local targetDist = render.Framebuffer_distance(renderbuffer, targetMask)
		factor(-targetDist/constraintTightness)
	end

	--print(numCircles)

	return circles
end


math.randomseed(os.time())

local t1 = os.clock()

local circles = MAP(generate, LARJTraceMH, {numsamps=1000, annealIntervals=200, globalTempMult=0.99, jumpFreq=0.05, verbose=true})
--local circles = MAP(generate, T3HMC, {numsamps=1000, numT3Steps=500, T3StepSize=0.02, globalTempMult=0.99, jumpFreq=0.05, verbose=true})
print(string.format("numCircles: %d", #circles))
render.Framebuffer_clear(renderbuffer_normal)
renderCircles(circles, renderbuffer_normal, true, fieldSmoothing, minMaxSmoothing)
render.Framebuffer_invert(renderbuffer_normal)
render.Framebuffer_saveToPNGImage(renderbuffer_normal, "test/output_smooth.png")
local finalbuffer = render.Framebuffer_new(500, 500, 0.0)
renderCircles(circles, finalbuffer, false, fieldSmoothing, minMaxSmoothing)
render.Framebuffer_invert(finalbuffer)
render.Framebuffer_saveToPNGImage(finalbuffer, "test/output.png")

local t2 = os.clock()
print(string.format("Time: %g", t2-t1))

render.Framebuffer_delete(finalbuffer)
render.Framebuffer_delete(renderbuffer_normal)
render.Framebuffer_delete(renderbuffer_hmc)
render.Framebuffer_delete(targetMask)


-- -- TEST
-- local fb = render.Framebuffer_new(500, 500, 0.0)
-- local circles = {{x=0.4, y=0.5, r=0.1}, {x=0.6, y=0.5, r=0.1}}
-- renderCircles(circles, fb, true, fieldSmoothing, minMaxSmoothing)
-- render.Framebuffer_invert(fb)
-- render.Framebuffer_saveToPNGImage(fb, "test/output_smooth.png")


----------------------------

fi.FreeImage_DeInitialise()





