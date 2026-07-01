-- Generate a deterministic undo file fixture for parser tests.
--
-- Invoked as:    nvim --clean -u tests/fixtures/generate.lua
-- Side effect:   writes tests/fixtures/sample.un~ and the buffer text it was
--                produced from, so parser tests can compare text snapshots.
--
-- The undo tree created here has three leafs and exercises the common code
-- paths: append, line delete, line insert. Timestamps will differ across
-- runs, but the byte layout (offsets, lengths, header sequence numbers) is
-- deterministic.

local fixture_dir = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ':p:h')
local buffer_path = fixture_dir .. '/sample.txt'
local undo_path    = fixture_dir .. '/sample.un~'

vim.opt.runtimepath:prepend(vim.fn.fnamemodify(fixture_dir, ':h') .. '/..')

vim.cmd.edit(buffer_path)
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  'hello world',
  'this is line 2',
  'foo bar baz',
})

vim.cmd('normal! ggA!')
vim.cmd('normal! Goops')

vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd('normal! gg2dd')

vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd('normal! oinserted at line 2')

vim.cmd('setlocal undofile')
vim.cmd('silent! write! ' .. vim.fn.fnameescape(buffer_path))
vim.cmd('silent! wundo! ' .. vim.fn.fnameescape(undo_path))
vim.cmd('qa!')