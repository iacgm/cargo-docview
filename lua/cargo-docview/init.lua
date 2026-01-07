-- This whole module is pretty hacky. But in theory it should work in the vast majority of cases.

local M = {}

local builtin_libs = {
	["rustc-std-workspace-std"] = "std",
	["std"] =  "std",
	["rustc-std-workspace-core"] = "core",
	["core"] =  "core",
	["rustc-std-workspace-alloc"] = "alloc",
	["alloc"] =  "alloc",
	["rustc-std-workspace-test"] = "test",
	["test"] =  "test",
	["rustc-std-workspace-proc_macro"] = "proc_macro",
	["proc_macro"] =  "proc_macro",
}

M.separator = "::"

--- @class Dep
--- @field direct boolean
--- @field lib string
--- @field version string

--- @return Dep[]
function M.get_deps()
	local cmd = vim.system({ "cargo", "metadata"})
	local cmd_no_deps = vim.system({ "cargo", "metadata", "--no-deps"})
	local metadata = vim.fn.json_decode(cmd:wait().stdout)
	local packages = metadata.packages

	local deps = {}
	for _, pkg in pairs(packages) do
		for _, dep in pairs(pkg.dependencies) do
			if builtin_libs[dep.name] then
				dep.name = builtin_libs[dep.name]
			end
			deps[dep.name] = {
				direct = false,
				lib = dep.name,
				version = dep.req,
			}
		end
	end

	-- Easier to just overwrite data than to parse metadata
	metadata = vim.fn.json_decode(cmd_no_deps:wait().stdout)
	for _, dep in pairs(metadata.packages[1].dependencies) do
		if builtin_libs[dep.name] then
			dep.name = builtin_libs[dep.name]
		end
		deps[dep.name] = {
			direct = true,
			lib = dep.name,
			version = dep.req,
		}
	end

	-- Close enough
	for _, lib in pairs(builtin_libs) do
		if deps[lib] then
			deps[lib].direct = true
		else
			deps[lib] = {
				direct = true,
				lib = lib,
				version = "^1.0",
			}
		end
	end

	local out = {}
	for _, dep in pairs(deps) do
		table.insert(out, dep)
	end

	return out
end

local function src_registry_path()
	---@diagnostic disable-next-line: undefined-field
	local cargo_home = vim.env.CARGO_HOME or vim.uv.os_homedir()

	local crates_path = cargo_home .. "/.cargo/registry/src"
	local dirs = vim.fn.readdir(crates_path)
	assert(#dirs == 1, "Unable to find source crates")
	local crates = dirs[1]

	return crates_path .. "/" .. crates
end

--- This just helps us find a matching library version
--- @param version string
--- @param pattern string
local function matches(version, pattern)
	local vs = vim.split(version, "%.")
	local major = vs[1]
	local minor = vs[2]
	local patch = vs[3]

	if pattern:sub(1, 1) == "^" then
		local rest = vim.split(pattern:sub(2), "%.")
		local pma = rest[1]
		local pmi = rest[2] or "0"
		local ppa = rest[3] or "0"
		-- Check version is new enough
		if (pma > major)
				or (pmi > minor and pma == major)
				or (ppa > patch and pma == major and pmi == minor) then
			return false
		end
		-- Check version is not too new
		if (pma == major and pma ~= 0)
				or (pmi == minor and pmi ~= 0 and pma == 0)
				or (ppa == patch and pma == 0 and ppa == 0) then
			return true
		else
			return false
		end
	end
	-- Other kinds of library requirements not yet supported.
	-- Let's just assume this pattern matches
	return true
end

--- @param lib string
--- @param pattern string
local function lib_path(lib, pattern)
	local libs = vim.fn.readdir(src_registry_path())
	for _, lib_dir in pairs(libs) do
		local split = vim.split(lib_dir, "-")
		local version = table.remove(split)
		local name = vim.fn.join(split, "-")

		if lib == name and matches(version, pattern) then
			return lib_dir
		end
	end

	error("Library not installed: `" .. lib .. "=" .. pattern .. "`")
end

--- @class Symbol
--- @field path string[]
--- @field kind string
--- @field info SymbolInfo

--- @class SymbolInfo
--- @field docs string[]?
--- @field file string
--- @field line integer

--- @param docs string
--- @return string[]
local function process_docs(docs)
	local text = ""
	local blocks = vim.split(docs, "```.-\n")
	for i, block in pairs(blocks) do
		if i % 2 == 1 then
			--- Block of text

			--- Diminishing returns on processing this further.
			--- Maybe best to just wait for rustdoc to support sanitizing this itself
			block = block:gsub("\n%-", "\n\n-")
			block = block:gsub("\n%*", "\n\n*")

			local inline_blocks = vim.split(block, "</?code>")
			for j, inline_block in pairs(inline_blocks) do
				if j % 2 == 0 then
					-- Remove links
					inline_block = inline_block:gsub("%[([^%]]-)%]%([^%<%)].-%)", "%1")

					-- Remove other brackets (this may break some snippets)
					-- TODO: Fix
					inline_block = inline_block:gsub("%[(.-)%]", "%1")

					-- Remove var tags
					inline_block = inline_block:gsub("<var>(.-)</var>", "%1")
				end
				inline_blocks[j] = inline_block
			end
			block = table.concat(inline_blocks, "`")

			local paragraphs = vim.split(block, "\n\n")
			for j, p in pairs(paragraphs) do
				paragraphs[j] = string.gsub(p, "%s+", " ")
				paragraphs[j] = vim.fn.trim(paragraphs[j])
			end
			block = table.concat(paragraphs, "\n\n")
		end

		if i % 2 == 1 then
			text = text .. block
		else
			text = text .. "```rust\n" .. block .. "```\n\n"
		end

	end

	return vim.split(text, "\n")
end

local function clone(xs)
	local out = {}
	for k, v in pairs(xs) do
		out[k] = v
	end
	return out
end

local function keys(t)
	local out = {}
	local n = 1
	for k, _ in pairs(t) do
		out[n] = k
		n = n + 1
	end
	return out
end

--- @param cwd string
--- @param json any
--- @return Symbol[]
local function process_json(cwd, lib, json)
	-- Scrap data we don't need.
	-- Releases memory
	json.target = nil
	json.external_crates = nil
	json.includes_private = nil

	local docs = {}

	local queue = { {json.root, {}} }
	for id, path in pairs({ json.paths }) do
		if path.kind == "primitive" then
			table.insert(queue, {tonumber(id), {}})
		end
	end

	local visited = {}
	while #queue ~= 0 do
		local req = table.remove(queue)
		local key = vim.inspect(req[1])
		local parent = req[2] -- When path is not available, we can sometimes recover it from the parent
		local entry = json.index[key]


		local path
		if json.paths[key] then
			path = json.paths[key].path
		elseif parent and entry.name then
			path = clone(parent)
			if entry.name ~= vim.NIL then
				table.insert(path, entry.name)
			end
		end

		local inners = keys(entry.inner)
		assert(#inners == 1)
		local kind = table.remove(inners)


		if not json.paths[key] and entry.inner.impl and entry.inner.impl.items then
				for _, item in pairs(entry.inner.impl.items) do
					table.insert(queue, {item, path})
				end
				goto continue
		elseif not json.paths[key] and entry.inner.use and json.index[vim.inspect(entry.inner.use.id)] then
			table.insert(queue, {entry.inner.use.id, path})
			goto continue
		end

		if kind == "type_alias" or kind == "trait_alias" then
			kind = "alias" -- Saves space in telescope picker
		end

		if visited[path] then
			goto continue
		end
		visited[path] = true

		local symbol = {
			path = path,
			kind = kind,
		}

		-- Note external exports do not appear in index
		if path[1] ~= lib then
			table.insert(docs, symbol)
			goto continue
		end

		local containers = {
			module = {"module", "items"},
			trait = {"trait", "items"},
			impl = {"impl", "items"},
			primitive = {"primitive", "impls"},
			struct = {"struct", "impls"},
			enum = {"enum", "impls"},
			union = {"union", "impls"},
		}

		if containers[kind] then
			-- Visit exported objects
			local items = entry.inner
			for _, f in pairs(containers[kind]) do
				items = items[f]
			end
			for _, item in pairs(items) do
				if not visited[item] and json.index[vim.inspect(item)] then
					table.insert(queue, {item, path})
				end
			end
		end

		-- Make path absolute
		local filename, line
		if entry.span ~= vim.NIL then
			filename = vim.fs.normalize(entry.span.filename)
			if filename ~= vim.fs.abspath(filename) then
				filename = cwd .. "/" .. vim.fs.normalize(filename)
			end
			line = entry.span.begin[1]
		end

		local info = {
			file = filename,
			line = line,
		}

		if entry.docs ~= vim.NIL then
			info.docs = process_docs(entry.docs)
		end

		symbol.info = info

		table.insert(docs, symbol)
		::continue::
	end

	return docs
end

function load_builtin(lib)
	local cmd = vim.system(vim.split("rustup which --toolchain nightly rustc", " ")):wait()

	assert(cmd.code == 0, "Could not find nightly toolchain docs")

	local cwd = vim.fs.normalize(cmd.stdout .. "/../../share/doc/rust/json")
	local path = cwd .. "/" .. lib .. ".json"

	local read = io.open(path)
	assert(read, "Could not find `" .. lib .. "` docs. You may need to install nightly, or run `rustup component add --toolchain nightly rust-docs-json`")

	local json = vim.fn.json_decode(read:read("*a"))
	assert(json, "Could not decode docs.")

	return process_json(path, lib, json)
end

--- @param lib string
--- @param version string
--- @return Symbol[]
function M.load_dep(lib, version)
	if builtin_libs[lib] then
		return load_builtin(builtin_libs[lib])
	end
	local path = src_registry_path() .. "/" .. lib_path(lib, version)
	local cmd = "cargo +nightly doc --no-deps --quiet"
	local doc = vim.system(vim.split(cmd, " "), {
		cwd = path,
		env = {
			RUSTDOCFLAGS = "-Zunstable-options -w json"
		}
	}):wait()
	assert(doc.code == 0, "Cargo doc failed. Maybe Nightly is not installed? Error: " .. vim.inspect(doc.stderr))

	local json = io.open(path .. "/target/doc/" .. lib .. ".json", 'r')
	assert(json, "Unable to read file")
	local docs = vim.fn.json_decode(json:read("*a"))
	vim.system({ "cargo", "clean" })

	return process_json(path, lib, docs)
end

M.name_hl = "rustIdentifier"
M.path_hl = "rustModPath"
M.highlight_map = {
	["type_alias"] = "rustType",
	["struct"] = "rustStructure",
	["function"] = "rustFunction",
	["constant"] = "rustConstant",
	["enum"] = "rustEnum",
	["union"] = "rustUnion",
	["primitive"] = "rustType",
	["macro"] = "rustMacro",
	["proc_derive"] = "rustDerive",
	["proc_attribute"] = "rustAttribute",
	["module"] = "rustModPath",
	["trait"] = "rustTrait",
	["variant"] = "rustEnumVariant"
}

return M
