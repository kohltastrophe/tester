local Sert = require("./Sert")

return {
	["handles promise resolve"] = function()
		local results = Sert.run({
			function()
				return {
					andThen = function() end,
					awaitStatus = function()
						task.wait(0.1)
						return true
					end,
				}
			end,
		}, nil, false, true)
		assert(results.PASSED == 1, "awaitStatus failed to pass")
	end,

	["handles promise rejection"] = function()
		local results = Sert.run({
			function()
				return {
					andThen = function() end,
					awaitStatus = function()
						return "Rejected", "promise error"
					end,
				}
			end,
		}, nil, false, true)
		assert(results.FAILED == 1, "promise rejection not handled")
	end,
}
