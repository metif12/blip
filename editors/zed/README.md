# blip for Zed

Zed can launch `blip lsp` as an external language server. Add to your Zed
settings:

```json
{
  "languages": {
    "Blip": {
      "language_servers": ["blip-lsp"]
    }
  },
  "lsp": {
    "blip-lsp": {
      "binary": {
        "path": "blip",
        "arguments": ["lsp"]
      }
    }
  }
}
```

Ensure `blip` is on your `PATH`.
