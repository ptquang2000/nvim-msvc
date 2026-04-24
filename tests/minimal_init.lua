vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.rtp:prepend(
    vim.fn.stdpath("data") .. "/site/pack/core/opt/plenary.nvim"
)
vim.cmd("runtime plugin/plenary.vim")
