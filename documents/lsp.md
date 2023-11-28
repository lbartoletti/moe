# Language Server Protocol

Moe supports [LSP](https://microsoft.github.io/language-server-protocol/) but work in progress and not recommended for use yet.

Currently, I only tested by [nimlsp](https://github.com/PMunch/nimlsp).

Please feedback, bug reports and PRs.

## Supported LSP commands

- `Initialize`
- `shutdown`
- `workspace/didChangeConfiguration`
- `textDocument/didOpen`
- `textDocument/didChange`
- `textDocument/didClose`
- `textDocument/hover`

## Configuration

Please edit you configuration file.

Example
```toml
[Lsp]
enable = true

[Lsp.nim]
# File extensions
extensions = ["nim"]

# The LSP server command
command = "nimlsp"
```

Configure each language by adding table `[Lsp.{languageId}]`.
If you want to add rust-analyzer,
```toml
[Lsp]
enable = true

[Lsp.nim]
extensions = ["nim"]
command = "nimlsp"

[Lsp.rust]
extensions = ["rs"]
command = "rust-analyzer"
```

## Uses

### Hover

Press `K` on the word in Normal mode.

![hover](https://github.com/fox0430/moe/assets/15966436/9e1f78d7-c52d-4bf7-bb51-7d86659ffeb5)