# Windows or WSL for Herdr and AgentPanel?

Assessment checked against official documentation on 14 September 2026. This is an architectural recommendation, not a measured benchmark on your machine.

**Keep this AgentPanel release on native Windows. Consider WSL2 for a future workspace whose projects and agent tools are primarily Linux-based.**

Herdr supports native Windows, but uses ConPTY rather than Unix PTYs. Its documentation describes differences in process detection and integration availability; Windows plugin support is still described as preview/best-effort. Linux avoids those particular Windows implementation paths. That is a reason to evaluate WSL, not a promise that every terminal problem disappears. [Herdr Windows support](https://herdr.dev/docs/windows-beta/)

| Your situation | Practical choice |
|---|---|
| You want this repository's dashboard working with your existing Windows agents | Native Windows. |
| Most work uses Linux shells, build tools and containers | Evaluate a Linux Herdr installation inside WSL2. |
| You need direct access to Windows-only apps and existing Windows credential setups | Staying native avoids an extra integration boundary. |
| You expect WSL to fix the reviewed script bugs | It will not. Those were application logic problems, now addressed in code. |
| You expect OpenRouter requests to become faster simply by changing OS | No such improvement has been demonstrated here. |

This repository is currently Windows-specific: `powershell.exe`, Windows process inspection (`Win32_Process`), named mutex naming, profile paths, launch commands and the Windows-only plugin manifest need a proper Linux implementation. Installing PowerShell 7 in WSL does not by itself provide the same runtime behavior. Invoking Windows PowerShell from WSL still runs a Windows process; it is not a Linux port.

For a WSL evaluation, keep the entire development toolchain together: Linux Herdr, Linux-installed agents and project files in the Linux filesystem, such as `~/projects`. Microsoft recommends keeping files with the operating system whose tools use them for performance, rather than working through `/mnt/c` by default. [Microsoft filesystem guidance](https://learn.microsoft.com/en-us/windows/wsl/filesystems)

A sensible migration would be:

1. Install WSL2 and a Linux distribution using [Microsoft's instructions](https://learn.microsoft.com/en-us/windows/wsl/install).
2. Install Linux Herdr using its [official installation guide](https://herdr.dev/docs/install/).
3. Try one noncritical project and its agent tools entirely inside that distribution.
4. Sign in to those Linux-installed tools separately; do not assume Windows credentials transfer.
5. Port and test AgentPanel's process ownership, startup, paths and locks before moving the dashboard.
6. Compare the same task on each setup, including pane recovery, keyboard behavior, file operations and tool startup.

Do not migrate the current live layout just to address these repository defects. The native fixes are independently useful, and a Linux port should be validated as a separate change.
