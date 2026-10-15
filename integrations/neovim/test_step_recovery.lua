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
local recovery = dofile("integrations/neovim/edb.lua")
recovery.setup(dap)
vim.notify = function() end
local passed = 0

local function new_session(adapter)
	local pending, restored = {}, {}
	local session = setmetatable({
		sign_group = "edb-recovery-test",
		config = { type = adapter or "edb" },
		stopped_thread_id = 1,
		threads = { [1] = { id = 1, stopped = true }, [2] = { id = 2, stopped = true } },
		event_stopped = function(self, event)
			self.stopped_thread_id = event.threadId
			self.threads[event.threadId].stopped = true
			restored[#restored + 1] = event.threadId
		end,
		request = function(_, command, arguments, callback)
			pending[#pending + 1] = { command = command, arguments = arguments, callback = callback }
			return "sent"
		end,
	}, { __index = Session })
	dap.listeners.on_session.edb_step_recovery(nil, session)
	local function respond(command, err, response)
		for i, request in ipairs(pending) do
			if request.command == command then
				table.remove(pending, i)
				request.callback(err, response)
				return
			end
		end
		error("No pending " .. command)
	end
	return session, respond, pending, restored
end

local failure = { message = "Missing beam_debug_info" }
local stack = { stackFrames = { { id = 1, line = 211 } } }
for _, command in ipairs({ "next", "stepIn", "stepOut" }) do
	local session, respond, _, restored = new_session()
	session:_step(command)
	respond(command, failure)
	respond("stackTrace", nil, stack)
	assert(session.stopped_thread_id == 1 and restored[1] == 1)
	passed = passed + 1
end

for _, condition in ipairs({ "running", "continued", "closed", "success", "other" }) do
	local session, respond, pending, restored = new_session(condition == "other" and "other" or nil)
	session:_step("stepIn")
	local err = failure
	if condition == "success" then
		err = nil
	end
	respond("stepIn", err)
	if condition ~= "success" and condition ~= "other" then
		if condition == "continued" then
			dap.listeners.before.event_continued.edb_step_recovery(session)
		elseif condition == "closed" then
			session.closed = true
		end
		respond("stackTrace", condition == "running" and failure or nil, stack)
	end
	assert(#restored == 0 and session.stopped_thread_id == nil and #pending == 0)
	passed = passed + 1
end

-- Both response orderings must discard an older recovery as soon as Continue
-- is dispatched, even though no Continue response/event has arrived yet.
for _, failure_first in ipairs({ true, false }) do
	local session, respond, pending, restored = new_session()
	session:_step("stepIn")
	if failure_first then
		respond("stepIn", failure)
	end
	session.stopped_thread_id = 2
	session:_step("continue")
	if failure_first then
		respond("stackTrace", nil, stack)
	else
		respond("stepIn", failure)
	end
	assert(#restored == 0 and session.stopped_thread_id == nil)
	respond("continue", nil, {})
	assert(#restored == 0 and session.stopped_thread_id == nil and #pending == 0)
	passed = passed + 1
end

-- A newer rejected step can recover its own thread without reviving the old one.
do
	local session, respond, pending, restored = new_session()
	session:_step("stepIn")
	respond("stepIn", failure)
	session.stopped_thread_id = 2
	session:_step("next")
	respond("next", failure)
	respond("stackTrace", nil, stack)
	assert(#restored == 0)
	respond("stackTrace", nil, stack)
	assert(restored[1] == 2 and #restored == 1 and #pending == 0)
	passed = passed + 1
end

do
	local session, _, pending = new_session()
	local request = session.request
	dap.listeners.on_session.edb_step_recovery(nil, session)
	recovery.setup(dap)
	dap.listeners.on_session.edb_step_recovery(nil, session)
	assert(session.request == request)
	assert(session:request("threads", {}, nil) == "sent" and #pending == 1)
	passed = passed + 1
end
print("Step recovery: " .. passed .. " cases passed")
vim.cmd("qa!")
