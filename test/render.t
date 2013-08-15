
local pr = require("probabilistic")
local util = require("probabilistic.util")
local fi = terralib.require("test.freeimage")
local hmc = terralib.require("probabilistic.hmc")
util.openpackage(pr)


fi.FreeImage_Initialise(0)

----------------------------

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

function Framebuffer:saveToPNGImage(filename)
	-- 24 bits per pixel (standard 8bit RGB)
	local img = fi.FreeImage_Allocate(self.width, self.height, 24, 0, 0, 0)
	local rgb = terralib.new(fi.RGBQUAD)
	for y=0,self.height-1 do
		for x=0,self.width-1 do
			local qval = quantize(self.buffer[y][x])
			rgb.rgbRed = qval
			rgb.rgbGreen = qval
			rgb.rgbBlue = qval
			rgb.rgbReserved = qval
			fi.FreeImage_SetPixelColor(img, x, y, rgb)
		end
	end
	-- 13 = PNG image type
	-- 0 = No extra flags
	fi.FreeImage_Save(13, img, filename, 0)
	fi.FreeImage_Unload(img)
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

-- This is the super naive "ray-tracing" version
-- (e.g. "for every pixel, for every circle")
-- Assumes the framebuffer has been initialized to white (i.e. 1.0)
local function render(circles, fb, fieldSmoothing, maxMinSmoothing)
	for y=0,fb.height-1 do
		local ypoint = (y + 0.5)/fb.height
		for x=0,fb.width-1 do
			local xpoint = (x + 0.5)/fb.width
			for i,c in ipairs(circles) do
				local f = c:fieldFunction(xpoint, ypoint)
				-- For now, just do a straight-up render (deal with smoothing later)
				if f <= 0 then
					fb:set(x, y, 0.0)
				end
			end
		end
	end
end


-- TEST
local fb = Framebuffer:new(double, 100, 100, 1.0)
local circles = {Circle:new(0.5, 0.5, 0.25)}
render(circles, fb, nil, nil)
fb:saveToPNGImage("test/output.png")


----------------------------

fi.FreeImage_DeInitialise()





