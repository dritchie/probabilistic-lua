
local M = {}


function M.map(func, tbl)
	local newtbl = {}
	for k,v in pairs(tbl) do
		newtbl[k] = func(v)
	end
	return newtbl
end

function M.filter(pred, tbl)
	local newtbl= {}
	for k,v in pairs(tbl) do
		if pred(v) then
			newtbl[k]=v
		end
	end
	return newtbl
end

function M.listfilter(pred, arr)
	local newtbl = {}
	for i,v in ipairs(arr) do
		if pred(v) then
			table.insert(newtbl, v)
		end
	end
	return newtbl
end

function M.keys(tab)
	local newtbl = {}
	for k,v in pairs(tab) do
		table.insert(newtbl, k)
	end
	return newtbl
end

function M.listToSet(tab)
	local set = {}
	for i,v in ipairs(tab) do
		set[v] = true
	end
	return set
end

function M.sum(...)
	local s = 0
	local n = select("#", ...)
	for i=1,n do
		s = s + select(i, ...)
	end
	return s
end

function M.sumtable(tab)
	local s = 0
	for k,v in pairs(tab) do
		s = s + v
	end
	return s
end

function M.normalize(arr)
	local total = 0
	for i,v in ipairs(arr) do
		total = total + v
	end
	for i,v in ipairs(arr) do
		arr[i] = v / total
	end
end

function M.arrayequals(a1, a2)
	if table.getn(a1) ~= table.getn(a2) then
		return false
	else
		for i,v in ipairs(a1) do
			if v ~= a2[i] then
				return false
			end
		end
		return true
	end
end

function M.cleartable(tab)
	for k,v in pairs(tab) do tab[k]=nil end
end

function M.copytable(tab)
	local newtbl = {}
	for k,v in pairs(tab) do
		newtbl[k] = v
	end
	return newtbl
end

function M.copytablemembers(srctab, dsttab)
	for k,v in pairs(srctab) do
		dsttab[k] = v
	end
end

function M.jointables(t1, t2)
	local res = M.copytable(t1)
	for k,v in pairs(t2) do
		res[k] = v
	end
	return res
end

function M.joinarrays(t1, t2)
	local res = M.copytable(t1)
	for i,v in ipairs(t2) do
		table.insert(res, v)
	end
	return res
end

function M.appendarray(srcarr, dstarr)
	for i,v in ipairs(srcarr) do
		table.insert(dstarr, v)
	end
end

function M.tabify(str, tablevel)
	tablevel = tablevel or 0
	for i=1,tablevel do str = "    " .. str end
	return str
end

function M.randomChoice(tbl)
	local n = table.getn(tbl)
	if n > 0 then
		return tbl[math.random(n)]
	else
		return nil
	end
end

function M.bool2int(b)
	return b and 1 or 0
end

function M.int2bool(i)
	return i ~= 0
end

function M.openpackage(ns)
	for n,v in pairs(ns) do
		rawset(_G, n, v)
	end
end

function M.inheritsFrom(child, parent)
	local visited = {}	-- avoid cycles
	if child == nil or parent == nil then
		return false
	end
	local mt = child
	repeat
		if visited[mt] then
			return false
		end
		visited[mt] = true
		mt = getmetatable(mt)
		if mt == parent then
			return true
		end
	until mt == nil
	return false
end

function M.guardedTerraRequire(filename)
	if terralib then
		return terralib.require(filename)
	else
		return nil
	end
end

function M.addReadonlyProperty(class, name, propfn)
	if not class.properties then
		class.properties = {}
	end
	class.properties[name] = propfn
	class.__index = function(self, key)
		local v = class[key]
		if v ~= nil then
			return v
		else
			local propfn = class.properties[key]
			if propfn then
				return propfn(self)
			else
				return nil
			end
		end
	end
end

function M.wait(procstr)
	io.popen(procstr):read("*all")
end

function M.capturingWait(procstr)
	return io.popen(procstr):read("*all")
end

-- Rudimentary cumulative timer class
M.Timer = {}

function M.Timer:new()
	local newobj = 
	{
		accum = 0,
		startime = nil
	}
	setmetatable(newobj, self)
	self.__index = self
	return newobj
end

function M.Timer:start()
	if not self:isRunning() then
		self.startime = os.clock()
	end
end

function M.Timer:stop()
	if self:isRunning() then
		local endtime = os.clock()
		self.accum = self.accum + (endtime - self.startime)
		self.startime = nil
	end
end

function M.Timer:isRunning()
	return self.startime ~= nil
end

function M.Timer:getElapsedTime()
	local time = self.accum
	if self:isRunning() then
		local curtime = os.clock()
		time = time + (curtime - self.startime)
	end
	return time
end

function M.Timer:reset()
	self:stop()
	self.accum = 0
end

-- exports
return M