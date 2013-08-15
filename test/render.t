
local pr = require("probabilistic")
local util = require("probabilistic.util")
local fi = terralib.require("test.freeimage")
local hmc = terralib.require("probabilistic.hmc")
util.openpackage(pr)


fi.FreeImage_Initialise(0)

----------------------------

local function setLessThanZeroErrorColor(rgb)
	rgb.rgbRed = 255
	rgb.rgbGreen = 0
	rgb.rgbBlue = 0
	rgb.rgbReserved = 255
end

local function setGreaterThanOneErrorColor(rgb)
	rgb.rgbRed = 0
	rgb.rgbGreen = 255
	rgb.rgbBlue = 0
	rgb.rgbReserved = 255
end

local function setNaNErrorColor(rgb)
	rgb.rgbRed = 0
	rgb.rgbGreen = 0
	rgb.rgbBlue = 255
	rgb.rgbReserved = 255
end

local function quantize(value)
	return math.floor(255.0 * value)
end

local function deQuantize(colorChannel)
	return colorChannel/255.0
end


local Framebuffer = {}

function Framebuffer:new(valtype, width, height, clearVal)
	local newobj =
	{
		valtype = valtype,
		width = width,
		height = height,
		clearVal = clearVal,
		buffer = terralib.new((valtype[width])[height])
	}
	for h=0,height-1 do
		newobj.buffer[h] = terralib.new(valtype[width], clearVal)
	end
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function Framebuffer:newFromMaskImage(filename)
	-- 13 = PNG image type
	-- 0 = No extra flags
	local img = fi.FreeImage_Load(13, filename, 0)
	local fb = Framebuffer:new(double, fi.FreeImage_GetWidth(img), fi.FreeImage_GetHeight(img), 0.0)
	local rgb = terralib.new(fi.RGBQUAD)
	for y=0,fb.height-1 do
		for x=0,fb.width-1 do
			fi.FreeImage_GetPixelColor(img, x, y, rgb)
			fb.buffer[y][x] = deQuantize(rgb.rgbRed)
		end
	end
	fi.FreeImage_Unload(img)
	return fb
end

function Framebuffer:clear()
	for y=0,self.height-1 do
		for x=0,self.width-1 do
			self.buffer[y][x] = self.clearVal
		end
	end
end

function Framebuffer:saveToPNGImage(filename)
	-- 24 bits per pixel (standard 8bit RGB)
	local img = fi.FreeImage_Allocate(self.width, self.height, 24, 0, 0, 0)
	local rgb = terralib.new(fi.RGBQUAD)
	for y=0,self.height-1 do
		for x=0,self.width-1 do
			local val = self.buffer[y][x]
			if val < 0.0 then
				--setLessThanZeroErrorColor(rgb)
				val = 0.0
			elseif val > 1.0 then
				setGreaterThanOneErrorColor(rgb)
			elseif val ~= val then
				setNaNErrorColor(rgb)
			else
				local qval = quantize(val)
				rgb.rgbRed = qval
				rgb.rgbGreen = qval
				rgb.rgbBlue = qval
				rgb.rgbReserved = qval
			end
			fi.FreeImage_SetPixelColor(img, x, y, rgb)
		end
	end
	-- 13 = PNG image type
	-- 0 = No extra flags
	fi.FreeImage_Save(13, img, filename, 0)
	fi.FreeImage_Unload(img)
end

function Framebuffer:invert()
	for y=0,self.height-1 do
		for x=0,self.width-1 do
			self.buffer[y][x] = 1.0 - self.buffer[y][x]
		end
	end
end

function Framebuffer:get(x, y)
	return self.buffer[y][x]
end

function Framebuffer:set(x, y, val)
	self.buffer[y][x] = val
end

function Framebuffer:distanceFrom(otherFb)
	assert(self.width == otherFb.width and self.height == otherFb.height)
	local dist = 0.0
	for y=0,self.height-1 do
		for x=0,self.width-1 do
			local diff = self.buffer[y][x] - otherFb.buffer[y][x]
			dist = dist + (diff*diff)
		end
	end
	return dist
end


local Circle = {}

function Circle:new(x, y, r)
	local newobj = 
	{
		x = x,
		y = y,
		r = r
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

-- Positive outside the circle
-- Negative inside
-- Zero on the boundary
function Circle:fieldFunction(x, y)
	local xdiff = x - self.x
	local ydiff = y - self.y
	return xdiff*xdiff + ydiff*ydiff - self.r*self.r
end


local function softmax(n, m, alpha)
	local en = math.exp(alpha*n)
	local em = math.exp(alpha*m)
	return (n*en + m*em)/(en + em)
end

local function softmin(n, m, alpha)
	local en = math.exp(-alpha*n)
	local em = math.exp(-alpha*m)
	return (n*en + m*em)/(en + em)
end

local function softmax2(n, m, alpha)
	return math.pow(math.pow(n, alpha) + math.pow(m, alpha), 1.0/alpha)
end

local function softmin2(n, m, alpha)
	return math.pow(math.pow(n, -alpha) + math.pow(m, -alpha), 1.0/-alpha)
end

local function over(cbot, ctop, abot, atop)
	return ctop*atop + cbot*abot*(1-atop)
end

local function over_alphaOnly(abot, atop)
	return atop + abot*(1-atop)
end

-- This is the super naive "ray-tracing" version
-- (i.e. "for every pixel, for every circle")
local function render(circles, fb, doSmoothing, fieldSmoothing, minMaxSmoothing)
	for y=0,fb.height-1 do
		local ypoint = (y + 0.5)/fb.height
		for x=0,fb.width-1 do
			local xpoint = (x + 0.5)/fb.width
			for i,c in ipairs(circles) do
				local f = c:fieldFunction(xpoint, ypoint)
				if doSmoothing then
					local currVal = fb:get(x, y)
					local newVal = math.exp(-f/fieldSmoothing)
					local blendVal = over_alphaOnly(currVal, newVal)
					local clampedBlendVal = softmin2(blendVal, 1.0, minMaxSmoothing)
					fb:set(x, y, clampedBlendVal)
				elseif f <= 0 then
					fb:set(x, y, 1.0)
				end
			end
		end
	end
end


local targetMask = Framebuffer:newFromMaskImage("test/mask_square_small.png")
targetMask:invert()

local renderbuffer_normal = Framebuffer:new(double, targetMask.width, targetMask.height, 0.0)
local renderbuffer_hmc = Framebuffer:new(hmc.num, targetMask.width, targetMask.height, hmc.makeNum(0.0))

local minMaxSmoothing = 200
local fieldSmoothing = 0.005

local function chooseRenderbuffer(number)
	if type(number) == "number" then
		return renderbuffer_normal
	else
		return renderbuffer_hmc
	end
end

local function generate()

	-- Params
	local numCircles_poissonLambda = 10
	local pos_min = 0.0
	local pos_max = 1.0
	-- local radius_betaAlpha = 2.0
	-- local radius_betaBeta = 5.0
	-- local radius_mult = 0.2
	local radius_min = 0.01
	local radius_max = 0.3
	local constraintTightness = 1.0

	-- Prior
	local numCircles = poisson({numCircles_poissonLambda}, {isStructural=true})
	local circles = {}
	for i=1,numCircles do
		--local r = radius_mult * beta({radius_betaAlpha, radius_betaBeta})
		local r = uniform({radius_min, radius_max})
		table.insert(circles, Circle:new(uniform({pos_min, pos_max}), uniform({pos_min, pos_max}), r))
	end

	-- Constraint
	if numCircles > 0 then
		local renderbuffer = chooseRenderbuffer(circles[1].x)
		renderbuffer:clear()
		render(circles, renderbuffer, true, fieldSmoothing, minMaxSmoothing)
		--render(circles, renderbuffer, false)
		local targetDist = renderbuffer:distanceFrom(targetMask)
		factor(-targetDist/constraintTightness)
	end

	--print(numCircles)

	return circles
end


math.randomseed(os.time())

local circles = MAP(generate, LARJTraceMH, {numsamps=1000, annealIntervals=0, globalTempMult=0.99, jumpFreq=0.05, verbose=true})
print(string.format("numCircles: %d", #circles))
local finalbuffer = Framebuffer:new(double, 500, 500, 0.0)
render(circles, finalbuffer, true, fieldSmoothing, minMaxSmoothing)
finalbuffer:invert()
finalbuffer:saveToPNGImage("test/output_smooth.png")
finalbuffer:clear()
render(circles, finalbuffer, false)
finalbuffer:invert()
finalbuffer:saveToPNGImage("test/output.png")


-- -- TEST
-- local fb = Framebuffer:new(double, 500, 500, 0.0)
-- local circles = {Circle:new(0.4, 0.5, 0.1), Circle:new(0.6, 0.5, 0.1)}
-- render(circles, fb, true, fieldSmoothing, minMaxSmoothing)
-- fb:invert()
-- fb:saveToPNGImage("test/output_smooth.png")


----------------------------

fi.FreeImage_DeInitialise()





