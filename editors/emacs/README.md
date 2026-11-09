# blip for Emacs

With `lsp-mode`:

```elisp
(with-eval-after-load 'lsp-mode
  (add-to-list 'lsp-language-id-configuration '(blip-mode . "blip"))
  (lsp-register-client
    (make-lsp-client
      :new-connection (lsp-stdio-connection '("blip" "lsp"))
      :major-modes '(blip-mode)
      :server-id 'blip)))
```

Use any Lisp-derived major mode or a custom `blip-mode` for `.lip` files.
```
