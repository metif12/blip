import * as vscode from "vscode"
import { startServer } from "./langserver"

const restartCommand = "blip.restartServer"

export function activate(context: vscode.ExtensionContext): void {
	let client = startServer(context)

	const status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 0)
	status.text = "$(check) blip"
	status.tooltip = "blip language server"
	status.command = restartCommand
	status.show()
	context.subscriptions.push(status)

	context.subscriptions.push(
		vscode.commands.registerCommand(restartCommand, async () => {
			await client.stop()
			client = startServer(context)
			vscode.window.showInformationMessage("blip language server restarted")
		}),
	)

	context.subscriptions.push(
		vscode.workspace.onDidChangeConfiguration(async (e) => {
			if (e.affectsConfiguration("blip.server")) {
				await client.stop()
				client = startServer(context)
			}
		}),
	)
}

export function deactivate(): void {}