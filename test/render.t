
local pr = require("probabilistic")
local util = require("probabilistic.util")
local fi = terralib.require("test.freeimage")
local hmc = terralib.require("probabilistic.hmc")
local render = terralib.require("renderer")
util.openpackage(pr)


fi.FreeImage_Initialise(0)

----------------------------

local targetMask = render.Framebuffer_newFromMaskImage("test/mask_square_small.png", 0.0)
render.Framebuffer_invert(targetMask)

local renderbuffer_normal = render.Framebuffer_new(render.Framebuffer_width(targetMask),
												   render.Framebuffer_height(targetMask),
												   0.0)
local renderbuffer_hmc = render.Framebuffer_new(render.Framebuffer_width(targetMask),
												   render.Framebuffer_height(targetMask),
												   hmc.makeNum(0.0))
--local minMaxSmoothing = 20
--local fieldSmoothing = 0.0025
local minMaxSmoothing = 5
--local fieldSmoothing = 0.2
local fieldSmoothing = 0.0025

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

local function generate(dim)

	-- Params
	local numCircles_poissonLambda = 50
	local pos_min = 0.0
	local pos_max = 1.0
	-- local radius_min = 0.005
	-- local radius_max = 0.05
	local radius_min = 0.005
	local radius_max= 0.5
	local constraintTightness = 0.1

	-- Prior
	local numCircles = dim or poisson({numCircles_poissonLambda}, {isStructural=true})
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
		--renderCircles(circles, renderbuffer, true, fieldSmoothing, minMaxSmoothing)
		renderCircles(circles, renderbuffer, true, fieldSmoothing, minMaxSmoothing)
		local targetDist = render.Framebuffer_distance(renderbuffer, targetMask)
		factor(-targetDist/constraintTightness)
	end

	--print(numCircles)

	return circles
end

local function makeFixedDimProg(dim)
	return function() return generate(dim) end
end


----------------------------

local verbose = false


math.randomseed(os.time())

local t1 = os.clock()

--local circles = MAP(generate, LARJTraceMH, {numsamps=10000, annealIntervals=200, globalTempMult=0.99, jumpFreq=0.05, verbose=verbose})
local samps = LMC(makeFixedDimProg(1), {numsamps=1000, verbose=verbose})
local circles = sampleMAP(samps)

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

print("Rendering movie of chain dynamics...")	
for i,s in ipairs(samps) do
	io.write(string.format(" frame %d\r", i))
	io.flush()
	render.Framebuffer_clear(renderbuffer_normal)
	renderCircles(s.returnValue, renderbuffer_normal, true, fieldSmoothing, minMaxSmoothing)
	render.Framebuffer_invert(renderbuffer_normal)
	render.Framebuffer_saveToPNGImage(renderbuffer_normal, string.format("test/movie_%03d.png", i-1))
end
io.write("\nCompressing movie...")
io.flush()
util.wait("ffmpeg -y -r 5 -i test/movie_%03d.png -c:v libx264 -r 5 -pix_fmt yuv420p test/chain_dynamics.mp4 2>&1")
util.wait("rm -f test/movie_*.png")
print("DONE.")

print("Rendering movie of gradients...")
for i,s in ipairs(samps) do
	io.write(string.format(" frame %d\r", i))
	io.flush()
	for i,v in ipairs(s.varlist) do
		s.varlist[i].val = hmc.makeNum(v.val)
	end
	hmc.toggleLuaAD(true)
	s:flushLogProbs()
	render.Framebuffer_gradientImage(renderbuffer_hmc, renderbuffer_normal, s.logprob)
	hmc.toggleLuaAD(false)
	render.Framebuffer_saveGradientImageToPNGImage(renderbuffer_normal, string.format("test/gradmovie_%03d.png", i-1))
end
io.write("\nCompressing movie...")
io.flush()
util.wait("ffmpeg -y -r 5 -i test/gradmovie_%03d.png -c:v libx264 -r 5 -pix_fmt yuv420p test/grad_dynamics.mp4 2>&1")
util.wait("rm -f test/gradmovie_*.png")
print("DONE.")

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





