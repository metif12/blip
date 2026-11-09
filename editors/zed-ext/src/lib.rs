use zed_extension_api::{self as zed, Command, LanguageServerId, Result, Worktree};

struct BlipExtension;

impl zed::Extension for BlipExtension {
    fn new() -> Self {
        Self
    }

    fn language_server_command(
        &mut self,
        _language_server_id: &LanguageServerId,
        _worktree: &Worktree,
    ) -> Result<Command> {
        Ok(Command {
            command: "C:/Users/MR/Projects/blip/blip.exe".to_string(),
            args: vec!["lsp".to_string()],
            env: Default::default(),
        })
    }
}

zed::register_extension!(BlipExtension);
