# tmux-save & tmux-restore

Minimalist utilities to **save** and **restore** your `tmux` session layout. Perfect for preserving your terminal workflow and picking up exactly where you left off — whether you're rebooting, switching machines, or just organizing your workspace.

---

## ✨ Features

- 📝 Save the complete tmux session layout — windows, panes, and split configurations
- 🔁 Restore the saved layout instantly in a new `tmux` session
- ⚡ Lightweight, fast, and dependency-free (just `bash` and `tmux`)

---

## 📦 Installation

Copy the scripts to a directory in your `PATH`:

```bash
cp tmux-save tmux-restore ~/bin/
chmod +x ~/bin/tmux-save ~/bin/tmux-restore
```

Ensure `~/bin` (or your chosen location) is included in your system’s `PATH`.

---

## 🛠 Usage

### Save the Current Session

```bash
tmux-save
```

This saves the layout of your current tmux session to `~/.tmux-sessions/`.  
You can automate this process using `cron` or `systemd` to back up your workspace periodically.

### Restore a Saved Session

```bash
tmux-restore
```

This restores your last saved layout, recreating windows and panes in a new tmux session.

---

## ✅ Requirements

- `tmux`
- `bash` or a compatible POSIX shell
- Unix-like OS (Linux, macOS, WSL)

---

## 📄 License

MIT License  
Use, modify, and share freely.
