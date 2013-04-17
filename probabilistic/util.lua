
module(..., package.seeall)


-- map(function, table)
-- e.g: map(double, {1,2,3})    -> {2,4,6}
function map(func, tbl)
	local newtbl = {}
	for i,v in pairs(tbl) do
		newtbl[i] = func(v)
	end
	return newtbl
end

-- filter(function, table)
-- e.g: filter(is_even, {1,2,3,4}) -> {2,4}
function filter(func, tbl)
	local newtbl= {}
	for i,v in pairs(tbl) do
		if func(v) then
			newtbl[i]=v
		end
	end
	return newtbl
end

function keys(tab)
	local newtbl = {}
	for k,v in pairs(tab) do
		table.insert(newtbl, k)
	end
	return newtbl
end

function sum(tab)
	local s = 0
	for k,v in pairs(tab) do
		s = s + v
	end
	return s
end

function arrayequals(a1, a2)
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

function cleartable(tab)
	for k,v in pairs(tab) do tab[k]=nil end
end

function openpackage (ns)
	for n,v in pairs(ns) do
		if _G[n] ~= nil then
			error("name clash: " .. n .. " is already defined")
		end
	_G[n] = v
	end
end