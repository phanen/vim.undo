-- Generate deterministic undo file fixtures for parser tests.
--
-- Invoked as:    nvim --clean -u src/testdata/generate.lua
-- Side effects:  writes src/testdata/sample.{txt,un~} (single-leaf tree) and
--                src/testdata/multitree.{txt,un~} (multi-leaf tree).
--
-- Both fixtures exercise the common code paths. The multi-leaf one is
-- required to demonstrate diffing between arbitrary undo leaves.
--
-- Use nvim_feedkeys with mode "tx" so each edit creates a distinct undo
-- step; without it, Vim coalesces consecutive normal-mode commands into
-- one undo point.

local fixture_dir = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ':p:h')
local function feed(keys) vim.api.nvim_feedkeys(keys, 'tx', false) end
local function writefile(lines, path)
    vim.fn.writefile(lines, path)
end

-- ---------------------------------------------------------------------------
-- Single-leaf fixture: four edits in one save, no undo.
-- ---------------------------------------------------------------------------
local single_path = fixture_dir .. '/sample.txt'
local single_undo = fixture_dir .. '/sample.un~'

writefile({ 'hello world', 'this is line 2', 'foo bar baz' }, single_path)
vim.cmd.edit(single_path)
feed('ggA!')
feed('Goops')
vim.api.nvim_win_set_cursor(0, { 1, 0 })
feed('gg2dd')
vim.api.nvim_win_set_cursor(0, { 1, 0 })
feed('oinserted at line 2\x1b')
vim.cmd('setlocal undofile')
vim.cmd('silent! write! ' .. vim.fn.fnameescape(single_path))
vim.cmd('silent! wundo! ' .. vim.fn.fnameescape(single_undo))

-- ---------------------------------------------------------------------------
-- Multi-leaf fixture: two edits, undo, third edit on a new branch, save.
-- ---------------------------------------------------------------------------
local multi_path = fixture_dir .. '/multitree.txt'
local multi_undo = fixture_dir .. '/multitree.un~'

writefile({ 'init' }, multi_path)
vim.cmd.edit(multi_path)
feed('GoappendA\x1b')
feed('GoappendB\x1b')
vim.cmd('silent! undo')
feed('GoappendC\x1b')
vim.cmd('setlocal undofile')
vim.cmd('silent! write! ' .. vim.fn.fnameescape(multi_path))
vim.cmd('silent! wundo! ' .. vim.fn.fnameescape(multi_undo))

vim.cmd('qa!')