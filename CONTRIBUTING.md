# Contributing to Closeup

Thanks for wanting to help! Closeup is a small personal project, so contributions of any size are welcome: bug fixes, new features, design tweaks, docs, or testing on your Mac.

## Fork it and make it yours

You're free to fork Closeup and change it however you like (it's [MIT licensed](LICENSE)). You don't need to send anything back. If you build something others would enjoy, a pull request is very welcome.

## Before you start

- **Small fixes** (typos, obvious bugs): just open a pull request.
- **Bigger changes** (a new feature, a redesign, a new dependency): open an [issue](../../issues) first and describe the idea. That way we can agree on the approach before you spend time on it.
- Check the [open issues](../../issues) and [pull requests](../../pulls) so you don't duplicate work.

## How to send a pull request

1. **Fork** the repo: click **Fork** at the top right of the GitHub page.
2. **Clone your fork** and make a branch for your change:
   ```bash
   git clone https://github.com/<your-username>/Closeup.git
   cd Closeup
   git checkout -b fix-camera-corner
   ```
3. **Open `Closeup.xcodeproj`**, choose your own Team under Signing & Capabilities, and press ⌘R.
4. **Make your change**, then test it with a real recording (see the checklist below).
5. **Commit and push** to your fork:
   ```bash
   git add .
   git commit -m "Fix the camera bubble jumping when changing corners"
   git push origin fix-camera-corner
   ```
6. On GitHub, open your fork and click **Compare & pull request**. Fill in the template.

I review every pull request myself. I may ask for changes, and it can take a few days.

## Guidelines

**Keep it Apple-only.** Closeup uses only Apple's frameworks, with no third-party packages. Please keep it that way unless we've agreed otherwise in an issue.

**Match the code around you.** Same naming, same comment style. Comments explain *why*, briefly. Keep functions readable; the project is meant to be easy to learn from.

**One change per pull request.** A bug fix and a new feature are two pull requests. Smaller ones get reviewed and merged faster.

**Don't commit personal settings.** Before committing, make sure:
- your **Team ID** isn't in `project.pbxproj` (Xcode adds it when you pick a team; set it back to `""`),
- no `build/` folder, recordings, or `xcuserdata/` are included (`.gitignore` covers these).

**Keep originals safe.** Closeup never changes the recorded files; edits live in `style.json`. New features should work the same way.

**Old recordings must still open.** If you add a setting to `ExportStyle`, read it with `decodeIfPresent` and a default, like the others.

## Testing checklist

Before you open a pull request, please check:

- [ ] It builds with no errors or new warnings.
- [ ] A new recording works: record, stop, and the editor opens.
- [ ] An older recording still opens.
- [ ] Export works and the MP4 plays.
- [ ] If you changed recording: memory stays reasonable during a 1–2 minute recording (check Activity Monitor).
- [ ] If you changed UI: it looks right in light and dark mode.

## Reporting bugs

Open an [issue](../../issues/new/choose) and include:
- your macOS version and Mac model,
- what you did, what you expected, and what happened,
- a screenshot or screen recording if you can,
- the crash report if it crashed (Console app → Crash Reports → Closeup).

## Be kind

Be respectful and patient in issues and reviews. Everyone here is learning.
