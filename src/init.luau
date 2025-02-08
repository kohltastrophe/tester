type Set = { [string]: any }
type Closure = (...any) -> ...any

local FOCUS = table.freeze({ type = "FOCUS" })
local SKIP = table.freeze({ type = "SKIP" })
local TIME = table.freeze({ type = "TIME" })

local SPAWN = if task
	then task.spawn
	else function(f, ...)
		local thread = coroutine.create(f)
		coroutine.resume(thread, ...)
		return thread
	end

local reservedKeys = {
	[FOCUS] = true,
	[SKIP] = true,
	[TIME] = true,

	after = true,
	afterEach = true,
	beforeEach = true,
	_async = true,
	_focus = true,
	_skip = true,
	_name = true,
}

local Tasks = {}
Tasks.__index = Tasks

function Tasks.new(async: boolean)
	return setmetatable({ num = 0, async = async, main = async and coroutine.running(), running = {} }, Tasks)
end

function Tasks:run(label: string, task: Closure, ...)
	task(...)
	self:taskDone(label)
end

function Tasks:spawn(label: string, task: Closure, ...)
	self.num += 1
	self.running[label] = true
	local process = if self.async then SPAWN else pcall
	local ok, err = process(Tasks.run, self, label, task, ...)
	if not ok then
		warn(err, 2)
	end
end

function Tasks:taskDone(label: string)
	self.num -= 1
	self.running[label] = nil
	if (self.async or self.defer == label) and self.num == 0 then
		coroutine.resume(self.main)
	end
end

function Tasks:wait()
	if (self.async or self.defer) and self.num > 0 then
		coroutine.yield()
	end
	table.clear(self.running)
	table.clear(self)
end

function Tasks:watch(name: string)
	task.wait(1)
	while self.num and self.num > 0 do
		print(`Waiting for {name}`)
		for label in self.running do
			print("  ⏳ " .. label)
		end
		task.wait(5)
	end
end

local function isPromise(object: Set)
	return type(object) == "table" and type(object.andThen) == "function" and type(object.awaitStatus) == "function"
end

local function runCase(key: string, case: Closure, test: Set, tasks: Set, results: Set)
	if test.beforeEach then
		local success, err = pcall(test.beforeEach)
		if not success then
			results.beforeEach = { _status = err }
			return
		end
	end

	local testStart = os.clock()
	local ok, result = pcall(case)
	if ok and isPromise(result) then
		local status, rejection = result:awaitStatus()
		if status == "Rejected" then
			ok, result = false, rejection
		end
	end

	results[key] = if result == "SKIP" then SKIP else { _status = ok or result, [TIME] = os.clock() - testStart }

	if test.afterEach then
		local success, err = pcall(test.afterEach)
		if not success then
			results.afterEach = { _status = err }
			results[key] = nil
		end
	end
end

local function runTest(test: Set, name: string, globals: Set?, globalAsync: boolean): Set | string
	if test.beforeEach and type(test.beforeEach) ~= "function" then
		return `function expected for {name}.beforeEach, got {type(test.beforeEach)}`
	end
	if test.afterEach and type(test.afterEach) ~= "function" then
		return `function expected for {name}.afterEach, got {type(test.afterEach)}`
	end
	if test.after and type(test.after) ~= "function" then
		return `function expected for {name}.after, got {type(test.after)}`
	end

	local results = {}
	local moduleStart = os.clock()
	local tasks = Tasks.new(globalAsync and test._async ~= false)
	SPAWN(tasks.watch, tasks, name)

	for key, case in test do
		if reservedKeys[key] then
			continue
		end
		if test._skip then
			results[key] = SKIP
			continue
		end
		if type(case) ~= "function" then
			results[key] = `{name} > {key}: function expected for test case, got {type(case)}`
			continue
		end
		if globals then -- PERF: DISABLES LUAU OPTIMIZATIONS
			setfenv(case, globals)
		end
		tasks:spawn(key, runCase, key, case, test, tasks, results)
	end

	tasks:wait()
	results[TIME] = os.clock() - moduleStart

	if test._focus then
		results[FOCUS] = true
	end

	if test.after then
		local success, err = pcall(test.after)
		if not success then
			results.after = { _status = err }
		end
	end

	return results
end

local function getResult(results: Set, globals: Set?, async: boolean, name: string, ok: boolean, test: any, tasks: Set)
	if test._focus or not results[FOCUS] then
		results[name] = if ok then runTest(test, name, globals, async) else test
	end
	tasks:taskDone(name)
end

local function run(object: Instance | Set, results: Set, globals: Set?, globalAsync: boolean, focus: boolean?): Set
	local isInstance = typeof(object) == "Instance"
	local isTable = typeof(object) == "table"
	local name = if isInstance then object.Name elseif typeof(object) == "table" then object._name or "Test" else "Test"
	local tasks = Tasks.new(globalAsync)
	local test

	if isInstance and object:IsA("ModuleScript") and name:find("%.test$") then
		_, test = pcall(require, object)
	elseif isTable then
		for k, v in object :: Set do
			if typeof(v) == "function" then
				test = object
				break
			end
		end
	end

	if test then
		local isTest = typeof(test) == "table"
		if isTest and test._focus then
			focus = true
			results[FOCUS] = true
		end
		tasks.num += 1
		tasks.defer = name
		tasks.running[name] = true
		tasks.main = tasks.main or coroutine.running()
		task.defer(getResult, results, globals, globalAsync, name, isTest, test, tasks)
	end

	local childResults = { [FOCUS] = focus }
	local children = if isInstance then object:GetChildren() elseif isTable then object else nil
	if children then
		for key, child in children do
			local childTable = typeof(child) == "table"
			if typeof(child) == "Instance" or childTable then
				if childTable then
					child._name = key
				else
					key = child.Name
				end
				tasks:spawn(key, run, child, childResults, globals, globalAsync, focus)
			end
		end
	end
	tasks:wait()

	if next(childResults) then
		local existing = results[name]
		if type(existing) == "table" then
			for k, v in childResults do
				existing[k] = v
			end
		else
			results[name] = childResults
		end
		if childResults[FOCUS] then
			results[FOCUS] = true
		end
	end

	return results
end

local function statusCount(results: Set): (number, number)
	local passed, failed, skipped = 0, 0, 0

	for _, value in results do
		if value == SKIP then
			skipped += 1
			continue
		end

		if typeof(value) == "table" then
			if value._status then
				if value._status == true then
					passed += 1
				else
					failed += 1
				end
			else
				local a, b, c = statusCount(value)
				passed += a
				failed += b
				skipped += c
			end
		elseif typeof(value) == "string" then
			failed += 1
		end
	end

	return passed, failed, skipped
end

-- Sert API

local Sert = { FOCUS = FOCUS, SKIP = SKIP, TIME = TIME }

function Sert.formatResults(results: Set, lines: { string }, depth: number): string
	local indent = string.rep(" ", depth * 2)
	local maxLength = 0
	for key in results do
		maxLength = math.max(maxLength, #tostring(key))
	end
	maxLength += 2

	for key, value in results do
		if typeof(value) == "table" then
			if value == SKIP then
				table.insert(lines, `{indent}  🟡 {key}`)
				continue
			end

			local elapsed = value[TIME]
			local time = if elapsed then tostring(math.round(elapsed * 1000)) .. " ms" else ""
			if value._status then
				local ok = value._status == true
				local status = if ok then "✅" else "❌"
				local err = ok and "" or `\n{indent}    ⚠️ {value._status}`
				local spacer = string.rep(" ", maxLength - #tostring(key))
				table.insert(lines, `{indent}  {status} {key}{spacer}{time}{err}`)
			else
				table.insert(lines, `{indent}{key}  {time}\n{Sert.formatResults(value, {}, depth + 1)}`)
			end
		elseif typeof(value) == "string" then
			table.insert(lines, `{indent}❌ {key}\n  {indent}⚠️ {value}`)
		end
	end

	table.sort(lines)
	return table.concat(lines, "\n")
end

function Sert.run(tests: Instance | Set, globals: Set?, async: boolean?, silent: boolean?): Set
	if not silent then
		print("Running Tests...")
	end

	async = if async == false then false else true
	local results = if typeof(tests) == "Instance" or typeof(tests) == "table"
		then run(tests, {}, globals, async :: boolean)
		else SKIP

	local passed, failed, skipped = statusCount(results)
	results.PASSED, results.FAILED, results.SKIPPED = passed, failed, skipped

	if silent then
		return results
	end

	print("Test Results:\n" .. Sert.formatResults(results, {}, 0))

	local status = ` | {passed} passed | {failed} failed | {skipped} skipped`
	if failed > 0 then
		warn("⚠️ Some tests failed! Check output for details." .. status)
	else
		print("✅ All tests passed!" .. status)
	end

	return results
end

return Sert
