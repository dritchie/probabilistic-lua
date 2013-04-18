
module(..., package.seeall)


-- Repeat a computation n times
function ntimes(times, block)
	for i=1,times do
		block(i)
	end
end

-- Invoke block for every value in tbl
function foreach(tbl, block)
	for k,v in tbl do
		block(v)
	end
end

-- Invoke block while condition is true
function whilst(condition, block)
	local cond = condition()
	while cond do
		block()
		cond = condition()
	end
end

-- Evaluate proc a bunch of times and build a table out of the results
function replicate(times, proc)
	local tbl = {}
	for i=1,times do
		table.insert(tbl, proc())
	end
	return tbl
end