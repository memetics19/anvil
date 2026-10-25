# The README's demo: install anvil with the one-line installer, then look around.
# Re-record from the repo root in a clean container, never on a real lab machine:
#   docker run --rm -v "$PWD":/vhs ghcr.io/charmbracelet/vhs docs/assets/anvil.tape
# Only help and version output appear: nothing here needs Vault, the Keychain or the lab.

Output docs/assets/anvil.gif

Require bash

Set Shell bash
Set FontSize 16
Set Width 1000
Set Height 640
Set Padding 20
Set Framerate 12
Set Theme "Catppuccin Mocha"
Set TypingSpeed 35ms
Set WaitTimeout 3m

# The VHS image has no curl. Install it and set a plain prompt before recording.
Hide
Type "export PS1='$ ' && apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq curl >/dev/null 2>&1 && clear"
Enter
Wait /^\$$/
Show

Type "curl -fsSL https://memetics19.github.io/anvil/install.sh | sh"
Sleep 300ms
Enter
Wait /^\$$/
Sleep 1500ms

Type "anvil version"
Sleep 200ms
Enter
Wait /^\$$/
Sleep 2s

Hide
Type "clear"
Enter
Wait /^\$$/
Show

Type "anvil --help"
Sleep 200ms
Enter
Wait /^\$$/
Sleep 4s

Hide
Type "clear"
Enter
Wait /^\$$/
Show

Type "anvil media --help"
Sleep 200ms
Enter
Wait /^\$$/
Sleep 3500ms

Hide
Type "clear"
Enter
Wait /^\$$/
Show

Type "anvil services --help"
Sleep 200ms
Enter
Wait /^\$$/
Sleep 3s
