# blip for Helix

Add to `~/.config/helix/languages.toml`:

```toml
[[language]]
name = "blip"
scope = "source.blip"
file-types = ["blip"]
roots = [".git"]
language-servers = ["blip-lsp"]

[language-server.blip-lsp]
command = "blip"
args = ["lsp"]
```

Helix will start `blip lsp` automatically for `.blip` files.
