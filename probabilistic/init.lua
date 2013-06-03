local submodules = {}
table.insert(submodules, require("probabilistic.trace"))
table.insert(submodules, require("probabilistic.erp"))
table.insert(submodules, require("probabilistic.inference"))
table.insert(submodules, require("probabilistic.control"))
table.insert(submodules, require("probabilistic.memoize"))
if terralib then
	table.insert(submodules, terralib.require("probabilistic.compiledInference"))
end

local M = {}

-- Forward exports
for i,m in ipairs(submodules) do
	for k,v in pairs(m) do
		M[k] = v
	end
end

return M