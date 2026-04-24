if vim.g.loaded_msvc == 1 then
    return
end
vim.g.loaded_msvc = 1

require("msvc.commands").register()
