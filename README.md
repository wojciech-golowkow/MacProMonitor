# Mac Pro Monitor

A small macOS app that watches another Mac over SSH:

- **Dock icon:** that machine's CPU history, in the style of Activity Monitor's "CPU History" icon. User time is green, system time is red, and the newest sample is on the right. The icon greys out and reads "offline" when the machine can't be reached.
- **Click the icon:** opens a window listing every Unity instance running there, editors and headless (`-batchmode`) runs alike. For each it shows Busy or Idle, the project, what it's doing (test filter, `-executeMethod`, import), CPU, memory, uptime and PID.

An instance counts as busy at 15% of one core or more, measured across its whole process tree. Unity compiles, imports and builds shaders in child processes, so the Unity process alone can look idle while it works.

## Set up

```sh
cp .env.example .env    # then edit .env
./build.sh
```

`.env` holds your machine-specific settings and stays out of git:

| Setting | Meaning |
|---|---|
| `REMOTE_HOST` | The Mac to watch, as `ssh` reaches it. |
| `SSH_IDENTITY_FILE` | Private key for that host. Leave it empty to use your ssh config and agent. |
| `BUNDLE_ID` | Your reverse-DNS app ID. It is also the `defaults` domain. |
| `UNITY_ENV_KEYS` | Optional. Environment variables of headless Unity runs to show in the Doing column, space-separated. |
| `CODESIGN_IDENTITY` | Optional. Defaults to the first "Apple Development" identity in your keychain, else ad hoc. |

`build.sh` compiles with `swiftc` (no Xcode project needed). It writes the settings into the app's `Info.plist` and installs the app into `~/Applications`.

To change a setting without rebuilding, set it with `defaults` and relaunch the app. The keys are `host`, `identityFile` and `unityEnvKeys`:

```sh
defaults write <BUNDLE_ID> host other-mac.local
```

## Requirements

- macOS 14 or later, on Apple silicon.
- The key must work without a passphrase prompt, because the app runs `ssh` with `BatchMode=yes`.
- The remote Mac needs nothing beyond macOS's own `top`, `ps` and `sysctl`.
- On first launch, macOS asks whether the app may find devices on your local network. Allow it, or SSH fails with "No route to host".
- If the app is signed with a real identity, macOS keeps that permission across rebuilds. An ad-hoc signature asks again after each build.

## Check without the GUI

```sh
"build/Mac Pro Monitor.app/Contents/MacOS/MacProMonitor" --dump
```

This prints the CPU split, the load and the parsed Unity instances once, then exits.
