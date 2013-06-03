
local M = {}


-- map(function, table)
-- e.g: map(double, {1,2,3})    -> {2,4,6}
function M.map(func, tbl)
	local newtbl = {}
	for i,v in pairs(tbl) do
		newtbl[i] = func(v)
	end
	return newtbl
end

-- filter(function, table)
-- e.g: filter(is_even, {1,2,3,4}) -> {2,4}
function M.filter(func, tbl)
	local newtbl= {}
	for i,v in pairs(tbl) do
		if func(v) then
			newtbl[i]=v
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

function M.sum(tab)
	local s = 0
	for k,v in pairs(tab) do
		s = s + v
	end
	return s
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


-- exports
return M