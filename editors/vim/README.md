# blip for Vim / Neovim

`blip lsp` works with any LSP client. Example (Neovim with nvim-lspconfig):

```lua
local lspconfig = require('lspconfig')
local configs = require('lspconfig.configs')
if not configs.blip then
  configs.blip = {
    default_config = {
      cmd = { 'blip', 'lsp' },
      filetypes = { 'blip' },
      root_dir = lspconfig.util.root_pattern('.git', 'v.mod'),
    },
  }
end
lspconfig.blip.setup({})
```

For Vim, use a plugin such as `vim-lsp` or `ale` and point it at `blip lsp`.

Set the filetype for `.lip` files:

```vim
autocmd BufRead,BufNewFile *.lip setfiletype blip
```
