# blip for Kate

Kate can use `blip lsp` as a language server over stdio. Syntax highlighting
is provided by Kate's generic Lisp highlighting (or any custom definition you
add); the server supplies diagnostics, hover, completion, go-to-definition,
references, rename, formatting, semantic tokens and more.

## Setup

1. Build blip:
   ```sh
   v -cc gcc -path 'vlib|@vlib' -o blip.exe main.v
   ```
   Make sure `blip.exe` is on your `PATH`.

2. In Kate, open **Settings → Configure Kate → LSP Client** and add a server
   for the `blip` language:

   ```json
   {
     "servers": {
       "blip": {
         "command": ["blip", "lsp"],
         "url": "stdio://",
         "highlightingModeRegex": "^Blip$"
       }
     }
   }
   ```

   If `blip` is not on PATH, use the absolute path to the executable.

3. Set the document type to **Lisp** (or create a custom highlighting mode)
   so `.lip` files are recognised.

4. Open a `.lip` file. Kate will start `blip lsp` and show diagnostics,
   hover, completion and the other features listed above.

## Notes

- The server speaks JSON-RPC 2.0 over stdio, exactly as LSP specifies.
- All features are provided by `blip lsp`; no extra plugins are required.
- Formatting is available through Kate's LSP formatting action.
