
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
local minMaxSmoothing = 5
local tightFieldSmoothing = 0.001
local looseFieldSmoothing = 0.1
local fieldBlend = 0.8

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
		doRender(circles, renderbuffer)
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

-- local d = render.Framebuffer_distance(renderbuffer_hmc, targetMask)
-- render.Framebuffer_gradientImage(renderbuffer_hmc, renderbuffer_normal, d)
-- render.Framebuffer_saveGradientImageToPNGImage(renderbuffer_normal, "test/gradientTestImg.png")

-- local w = render.Framebuffer_width(targetMask)
-- local h = render.Framebuffer_height(targetMask)
-- hmc.toggleLuaAD(true)
-- local indeps = terralib.new(hmc.num[w*h])
-- local d = 0.0
-- local derivAccum = 0.0
-- for y=0,h-1 do
-- 	for x=0,w-1 do
-- 		local hmcp = render.Framebuffer_getPixelValue(renderbuffer_hmc, x, y)
-- 		local tgtp = render.Framebuffer_getPixelValue(targetMask, x, y)
-- 		local diff = hmcp - tgtp
-- 		d = d + diff*diff
-- 		indeps[y*w + x] = hmcp
-- 		derivAccum = derivAccum + 2 * diff
-- 	end
-- end
-- local gradient = terralib.new(double[w*h])
-- hmc.gradient(d, w*h, indeps, gradient)
-- hmc.toggleLuaAD(false)
-- for i=0,w*h-1 do
-- 	print(gradient[i])
-- end
-- print("-----")
-- print(hmc.getValue(derivAccum))

-- local x = 20
-- local y = 20
-- hmc.toggleLuaAD(true)
-- local indeps = terralib.new(hmc.num[1])
-- local hmcp = render.Framebuffer_getPixelValue(renderbuffer_hmc, x, y)
-- local tgtp = render.Framebuffer_getPixelValue(targetMask, x, y)
-- local diff = hmcp - tgtp
-- local dep = diff*diff
-- indeps[0] = hmcp
-- local gradient = terralib.new(double[1])
-- hmc.gradient(dep, 1, indeps, gradient)
-- hmc.toggleLuaAD(false)
-- print(string.format("indep var val: %g", hmc.getValue(hmcp)))
-- print(string.format("mask value: %g", tgtp))
-- print(string.format("dep var val: %g", hmc.getValue(dep)))
-- print(string.format("gradient: %g", gradient[0]))

----------------------------

local verbose = true


math.randomseed(os.time())

local t1 = os.clock()

local samps = LMC(makeFixedDimProg(2), {numsamps=1000, verbose=verbose})
--local samps = LARJTraceMH(makeFixedDimProg(40), {numsamps=1000, verbose=verbose})
local circles
local finallp
circles, finallp = sampleMAP(samps)

--print(string.format("numCircles: %d", #circles))
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


----------------------------


-- -- TEST
-- local fb = render.Framebuffer_new(500, 500, 0.0)
-- local circles = {{x=0.4, y=0.5, r=0.1}, {x=0.6, y=0.5, r=0.1}}
-- renderCircles(circles, fb, true, fieldSmoothing, minMaxSmoothing)
-- render.Framebuffer_invert(fb)
-- render.Framebuffer_saveToPNGImage(fb, "test/output_smooth.png")


----------------------------

fi.FreeImage_DeInitialise()





