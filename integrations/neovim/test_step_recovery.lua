-- SPDX-License-Identifier: Apache-2.0
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     https://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Run with nvim-dap on runtimepath:
-- nvim --clean --headless --cmd 'set rtp+=/path/to/nvim-dap' -l integrations/neovim/test_step_recovery.lua
local dap = require("dap")
local Session = require("dap.session")
dofile("integrations/neovim/edb.lua").setup(dap)
vim.notify = function() end

local function run(options)
	local restored = false
	local session = setmetatable({
		sign_group = "edb-recovery-test",
		config = { type = options.adapter or "edb" },
		stopped_thread_id = 1,
		threads = { [1] = { id = 1, stopped = true }, [2] = { id = 2, stopped = true } },
		event_stopped = function(self, event)
			assert(event.threadId == 1)
			self.stopped_thread_id = event.threadId
			self.threads[event.threadId].stopped = true
			restored = true
		end,
		request = function(self, command, arguments, callback)
			if command == "stackTrace" then
				if options.stale then
					dap.listeners.before.event_continued.edb_step_recovery(self)
				end
				callback(
					options.running and { message = "Process is not paused" } or nil,
					{ stackFrames = { { id = 1, line = 211 } } }
				)
			else
				local err
				if not options.success then
					err = { message = "Missing beam_debug_info" }
				end
				dap.listeners.before[command].edb_step_recovery(self, err, nil, arguments)
				callback(err)
				dap.listeners.after[command].edb_step_recovery(self, err, nil, arguments)
			end
		end,
	}, { __index = Session })
	session:_step(options.command or "stepIn")
	return session, restored
end

for _, command in ipairs({ "next", "stepIn", "stepOut" }) do
	local session, restored = run({ command = command })
	assert(restored and session.stopped_thread_id == 1 and session.threads[1].stopped)
end
for _, options in ipairs({ { running = true }, { stale = true }, { success = true }, { adapter = "other" } }) do
	local session, restored = run(options)
	assert(not restored and session.stopped_thread_id == nil)
end
print("Step recovery: 7 cases passed")
vim.cmd("qa!")
