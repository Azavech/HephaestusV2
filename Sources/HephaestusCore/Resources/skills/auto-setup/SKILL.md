---
name: auto-setup
description: Sets up a macOS image of HephaestusV2 in its setup virtual machine, from Setup Assistant to Finish Setup. The first message of an Auto Setup chat calls it with the image's id.
---

# Set up a macOS image

This is an Auto Setup chat. Set up the image $ARGUMENTS in its setup virtual machine, which runs now, by driving it with the VM tools: its id in vm_list and the vmID of the actions is the image's id. The user may already have started the setup: take a screenshot first and start at the step that the guest's screen shows. Follow these steps:

1. **Account.** Call vm_list_images and read the userName and password of the image. When either is missing, ask the user for both with ask_questions and end your turn; when the answers arrive, store them with vm_set_account before you go on. Use this account wherever the steps below ask for a user name or a password.
2. **Setup Assistant.** Choose the language English and the region United States. Create the account with the stored user name, as full name and account name, and the stored password. Agree to the macOS licence agreement without asking the user. Skip, or turn off, every optional screen: Apple Account, Location Services, Analytics, Siri, Screen Time and the like. Once the desktop shows, turn on automatic login for the account in System Settings ▸ Users & Groups, typing the password when macOS asks for it.
3. **SIP off.** Call vm_setup_recovery. When macOS asks whether to shut down, choose Shut Down within 30 seconds. At the startup options, choose Options, then Continue. In Recovery, open Utilities ▸ Terminal and run csrutil disable, confirming with y and typing the user name and the password when they are asked for. Then restart from the Apple menu ▸ Restart: macOS starts up normally and logs in by itself.
4. **The agent.** Open Terminal, from the Finder: Applications ▸ Utilities ▸ Terminal. Run sh "/Volumes/My Shared Files/install.sh" and type the password when sudo asks for it. Wait until the script has ended, and report its last lines when it fails.
5. **Finish Setup.** Check with vm_list that the setup virtual machine's agentConnected is true, then call vm_setup_finish: it shuts the virtual machine down and the image becomes Ready. When it fails because the agent does not report SIP off, go back to step 3.

Reply with a short summary of the setup: the account, the steps done and the image Ready. Do not close this chat: it stays open when the setup ends.
