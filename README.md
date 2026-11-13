# OSPOS installer

Scripts to install [Open Source Point of Sale (OSPOS)](https://github.com/opensourcepos/opensourcepos),
a web-based point of sale system, on Windows or Ubuntu/Debian, including fully offline use.

| Folder | What it is |
|---|---|
| `offline/` | A **prebuilt copy of OSPOS** (all PHP libraries and front-end files already included), so no build tools are needed. Currently `3.4.4-dev`, built from OSPOS commit `483802a`. |
| `windows/` | Windows 10/11 installer: portable PHP 8.3 + MariaDB 10.11 in one folder (default `C:\OSPOS`). |
| `linux/` | Ubuntu/Debian installer: Apache + MariaDB + PHP 8.3. |

After installing, open OSPOS in a browser, click **Initialize** (first visit only) to create the
database tables, then log in with **`admin` / `pointofsale`** and change that password right away.

## Windows laptop

1. On GitHub click **Code > Download ZIP** (or `git clone` this repo) and unzip it, for example to your Desktop.
2. Open the `windows` folder and double-click **`install.bat`**.
   - If Windows SmartScreen warns about the file, click *More info > Run anyway*.
   - If the Microsoft Visual C++ runtime is missing, Windows asks once for permission to install it.
3. Your browser opens `http://localhost:8080/`. Click **Initialize**, then log in.

From then on use the **Start OSPOS** and **Stop OSPOS** shortcuts on the desktop. OSPOS runs only on
this laptop and works without internet. Your shop data is in `C:\OSPOS\data`, so back that folder up
(stop OSPOS first). Passwords are in `C:\OSPOS\credentials.txt`.

### Offline install (laptop with no internet at all)

The installer downloads PHP and MariaDB once (about 110 MB) and keeps them in `windows\downloads`.
To install on a laptop that is never online:

1. On any Windows PC with internet, run this in a Command Prompt inside the `windows` folder:
   ```bat
   install.bat -DownloadOnly
   ```
2. Copy the whole folder, including `windows\downloads`, to a USB stick.
3. On the offline laptop, double-click `windows\install.bat`.

Options: `install.bat -InstallDir D:\OSPOS -Port 8081 -DbPort 3308`.

## Ubuntu / Debian

```bash
sudo bash linux/install-ospos.sh
```

Then open `http://localhost/`. Use `--from-source` to download and build the latest OSPOS code
instead of the prebuilt copy (needs Composer and Node.js 22+). Database credentials are written to
`/root/ospos-credentials.txt`.

## Notes

- This is the OSPOS **development** version (`3.4.4-dev`). For a real shop, the OSPOS team recommends an
  [official release](https://github.com/opensourcepos/opensourcepos/releases).
- OSPOS checks the address you type in the browser. The installers allow `localhost` and `127.0.0.1`
  (on Windows with the port, for example `localhost:8080`). To reach it from another device, add that
  name to `app.allowedHostnames` in the `.env` file inside the OSPOS folder.
- To refresh the prebuilt copy, build OSPOS (`composer install --no-dev`, `npm install`, `npm run build`),
  leave out `node_modules`, `.git`, `tests` and `.env`, and zip the result as `offline/ospos-<version>-<commit>-prebuilt.zip`
  with a single top-level `ospos/` folder.
