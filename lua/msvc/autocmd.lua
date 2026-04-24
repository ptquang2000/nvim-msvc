---@class MsvcAutocmd
---@field group integer The shared augroup id used by every nvim-msvc autocmd.
---@field name string The augroup name ("MsvcAugroup").

local AUGROUP = "MsvcAugroup"

return {
    name = AUGROUP,
    group = vim.api.nvim_create_augroup(AUGROUP, { clear = true }),
}
